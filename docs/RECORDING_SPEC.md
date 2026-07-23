# Continuous Recording — Feature Spec

Status: **implemented** (shipped in v0.4.0; audio added). This began as a design pass
(2026-07) and the sections below describe the shipped design. Video-only recordings are
`.mp4`; recordings with audio are `.mov` (H.264 + PCM) — see the "Audio" section.

Local, continuous, per-camera recording to disk: 60-second segments, organised
into dated folders, auto-pruned after a retention window. Opt-in per camera via a
checkbox next to “Show video stream”.

---

## 1. Goal & scope

- Save each recording-enabled camera's live stream to local `.mp4` files.
- Fixed-length segments (default **60 s**), one file per segment.
- Files named `{camera}-{YYYYMMDD_HHMMSS}.mp4`, filed under
  `{base}/{camera}/{YYYY-MM}/{DD}/{HH}/`.
- Retention: delete anything older than **N hours** (default **48**).
- Per-camera opt-in (a “Record video” switch), plus a small global settings block
  (base folder, retention hours).
- **Non-goals (v1):** cloud upload, motion-triggered clips, in-app playback,
  video transcoding/resolution change, exporting.

### Audio (added after v1)

Optional per-camera **“Record audio”** sub-toggle. The demuxer (`rtsp_demux.c`) now
also extracts the audio stream and hands packets + codec info to Swift. Wyze cams
stream **G.711 A-law** (mono 16 kHz), which MP4 can't hold, so audio recordings are
written as **`.mov`** with the audio decoded to **16-bit PCM** in-app (`Audio.swift`,
a lookup-table G.711 expander — no encoder) and muxed as a second `AVAssetWriter`
track. Audio PTS is anchored to the video session start and kept contiguous per
segment for smooth, roughly-synced playback. Cameras without audio (or with an
unsupported codec, e.g. AAC — not yet wired) fall back to video-only `.mp4`. Live
view stays silent — this is recording-only, so the latency path is untouched.

## 2. Guiding constraint

The product's north star is **glass-to-glass latency**. Recording must be a
*passive tap* that never touches or slows the demux → parse → `AVSampleBufferDisplayLayer`
render path. Recording is **best-effort**: if it falls behind or fails, live view
must be completely unaffected.

## 3. Why this is a stream-copy (the key insight)

By the time frames reach Swift they are **already compressed H.264**:

- `CRTSPDemux` demuxes RTSP and emits Annex-B bytes (SPS/PPS are emitted before
  every keyframe — the `dump_extra=freq=keyframe` behaviour documented in
  `rtsp_demux.h`).
- `H264Parser` splits NALs, builds a `CMVideoFormatDescription` from SPS(7)/PPS(8),
  and wraps each slice NAL (types 1/5) as an AVCC `CMSampleBuffer`.

So we already hold exactly what an `.mp4` needs: compressed samples + a format
description. Recording = **mux those samples into a container, no re-encode**
(`AVAssetWriter` passthrough). This means ~zero CPU, no quality loss, and no
decode dependency.

## 4. The core problem: timestamps

`H264Parser.makeSampleBuffer` currently creates sample buffers with **no timing**
(`sampleTimingEntryCount: 0`) and tags them `DisplayImmediately`. libavformat's
packet PTS/DTS are discarded at the C byte-callback boundary (`rtsp_demux_data_cb`
passes only `const uint8_t *data, int len`). MP4/MOV require per-sample timing.

**Chosen solution — synthesize PTS from the host clock at arrival:**

- Stamp each sample with `PTS = CMClockGetTime(CMClockGetHostTimeClock())` at the
  moment the NAL is parsed. Use `PTS` for both presentation and decode time.
- This is valid **iff the stream has no B-frames** (decode order == presentation
  order). Evidence it holds: the live path renders correctly with
  `DisplayImmediately` and *no reordering* — B-frames would visibly break that.
  Still, treat “no B-frames” as an **assumption to verify per camera** (see §12).

**Why not extend the C layer to pass real PTS/DTS?** It's more correct but means
threading a muxer through the latency-critical demux thread and writing an MP4
muxer in C — more risk to the thing we must not perturb. Rejected for v1;
revisit only if host-clock timing proves inadequate (see §14, Alternative B).

### 4.1 Required change to `H264Parser`

Modify `makeSampleBuffer` to attach timing + sync info (keep `DisplayImmediately`
so live latency is unchanged — it overrides scheduling regardless of PTS):

- Provide a `CMSampleTimingInfo` with `presentationTimeStamp = hostTime`,
  `decodeTimeStamp = .invalid`, `duration = .invalid`.
- Set `kCMSampleAttachmentKey_NotSync = true` on **non-IDR** slices (type 1);
  leave it unset/false on **IDR** slices (type 5). This lets the recorder detect
  keyframes for segment alignment and lets players seek.

Both consumers (display + recorder) then share the same timed sample buffer. Live
display behaviour is unchanged.

## 5. Architecture

```
CRTSPDemux ──bytes──► H264Parser ──timed CMSampleBuffer──► RTSPSource.onSampleBuffer
                                                                │
                                        ┌───────────────────────┴───────────────┐
                                        ▼ (main thread, as today)               ▼ (recording serial queue)
                              VideoLayerView.enqueue                    CameraRecorder.append
                              (unchanged, priority)                     (best-effort, isolated)
```

New components (all Swift, no C):

- **`CameraRecorder`** (`Sources/LocalVideoNative/CameraRecorder.swift`)
  Owns the `AVAssetWriter`/`AVAssetWriterInput` for one camera, does segment
  rotation, keyframe alignment, and file finalisation. One instance per
  recording-enabled camera. All work on a per-camera serial `DispatchQueue`
  (`localvideo.recorder.<id>`), never on the demux or main thread.

- **`RecordingStore`** (`Sources/LocalVideoNative/RecordingStore.swift`)
  Path construction (`{base}/{camera}/{YYYY-MM}/{DD}/{HH}/…`), filename
  formatting, retention pruning timer, disk-space checks, empty-dir cleanup.

- **`RecordingSettings`** (part of `Config.swift`)
  Global block: base directory, retention hours, segment seconds.

Wiring:

- `RTSPSource` gains an optional `onSampleBufferForRecording` (or the recorder is
  attached and `onSampleBuffer` fans out to both). It hands the sample buffer to
  the recorder via `recorder?.queue.async { recorder.append(sb) }`.
- `AppDelegate` owns `recorders: [UUID: CameraRecorder]` and a single
  `RecordingStore`, mirroring how it owns `sources` and `tilesById`.

## 6. Streaming lifecycle change

Today a camera gets an `RTSPSource` only when `showVideoStream == true`
(`AppDelegate.applyCameras` builds tiles/streams from `shownCameras`). Recording
must work even for a camera hidden from the grid.

**Rule:** a camera has a live `RTSPSource` when **`showVideoStream || recordVideo`**.

- The grid **tile** still appears only when `showVideoStream` is true.
- The **recorder** attaches whenever `recordVideo` is true (regardless of tile).
- `applyCameras`'s diff extends from `shouldShow` to `shouldStream =
  showVideoStream || recordVideo`. A camera toggled record-on but show-off starts
  a source with no tile; toggled fully off stops the source.
- Health-check / auto-reconnect already keys off `sources`, so a
  record-only camera reconnects on stall like any other. `reconnect(id:)`'s
  “never resurrect a hidden camera” guard must widen to “…unless recording”.

## 7. Config schema (`cameras.json`)

Backward-compatible additions (absent ⇒ defaults, like `showVideoStream`):

Per camera (`CameraConfig`):
```json
{ "…": "…", "recordVideo": false }
```

New top-level block (`CamerasFile` gains an optional `recording`):
```json
{
  "cameras": [ … ],
  "recording": {
    "directory": "/Users/me/Movies/LocalVideo",
    "retentionHours": 48,
    "segmentSeconds": 60
  }
}
```

Defaults if the block/keys are missing:
- `directory` → `~/Movies/LocalVideo`
- `retentionHours` → `48`
- `segmentSeconds` → `60`

`Config.load/save` and the `CamerasFile` struct extend to (de)serialise this;
`RecordingSettings` provides typed access with the defaults above.

## 8. UI (Preferences panel)

Mirror the existing `showStreamCheckbox` pattern in `PreferencesWindowController`:

- **Per-camera:** add a `Record video` switch under `Show video stream`
  (`NSButton .switch`), bound to `recordVideo`, applied on **Save** through
  `applyCameras` (no live side effect beyond start/stop of the source+recorder).
  Dim/annotate the camera-list row when recording (e.g. a small ● REC hint) —
  optional polish.
- **Global (bottom of the form or a small section):**
  - `Recordings folder:` read-only path + **Choose…** (`NSOpenPanel`, directories).
  - `Keep last [ 48 ] hours` numeric field (`NSTextField`, validated ≥ 1).
- Validation: retention must be a positive integer; folder must be writable
  (probe with a temp file, surface via the existing `errorLabel`).

The panel is `nonactivatingPanel` and edits route through `applyCameras`, so this
fits the current flow with no architectural change.

## 9. On-disk layout & naming

```
{base}/{camera}/{YYYY-MM}/{DD}/{HH}/{camera}-{YYYYMMDD_HHMMSS}.mp4
```
Example:
```
~/Movies/LocalVideo/Front Door/2026-07/21/14/Front Door-20260721_143012.mp4
```

- **Local time** for all path/name components (note DST: the 25-hour day just
  yields two files in the same `HH` — harmless; the 23-hour day skips one).
- **Sanitise** the camera name for the filesystem: replace `/ : \0` and trim; keep
  spaces (paths are quoted everywhere). Collisions across cameras are avoided by
  the top-level `{camera}` folder.
- **Seconds in the filename** (`HHMMSS`, not just `HHMM`) so a mid-minute rotation
  (format change, restart) can't collide.
- A partially written segment uses a `.mp4.partial` suffix, renamed to `.mp4` only
  on successful finalisation (so the pruner and any future playback never touch a
  half-written file).

## 10. Segmentation & keyframe alignment

- Each segment targets `segmentSeconds` (default 60), but **rotates at the first
  IDR at or after** the boundary, so every file starts with a keyframe + SPS/PPS
  and is independently decodable.
- Consequence: real segment length depends on the camera's **GOP/keyframe
  interval**. With a 1–2 s keyframe interval, segments are ~60–62 s. With a very
  long GOP (e.g. 10 s), a segment can overshoot; if the keyframe interval is
  longer than `segmentSeconds`, files will simply be one-GOP long. Document this;
  don't force a cut mid-GOP (that produces non-seekable, non-standalone files).
- **Rotation procedure** (on the recorder queue):
  1. On an incoming keyframe, if `now - segmentStart >= segmentSeconds`, finalise
     the current writer **asynchronously** (`finishWriting`), rename
     `.partial → .mp4`, and open a new writer whose first sample is this keyframe.
  2. Never drop frames during rotation: buffer the keyframe that triggers rotation
     as the first sample of the new segment.
- **First start:** wait for the first IDR before opening the first writer (samples
  before the first keyframe are dropped — a sub-second warm-up).
- **Format change mid-stream** (resolution/SPS change ⇒ new
  `CMVideoFormatDescription`): `AVAssetWriter` can't change format mid-file →
  finalise and start a new segment on the new format's first keyframe.

## 11. Robustness (crash / quit / disk)

- **Crash resilience:** set `assetWriter.movieFragmentInterval` (e.g. 1–5 s) so the
  file is written as fragments. If the app crashes mid-segment, the fragments
  already flushed remain playable; at most the last interval is lost. Without
  this, a non-finalised MP4 has no `moov` atom and is unplayable.
- **Clean quit:** in `applicationWillTerminate`, stop the demux as today, then
  `finishWriting` on all active recorders with a bounded wait (e.g. up to ~2 s
  total) before exit. Rename any surviving `.partial` on next launch (startup
  sweep: any `.mp4.partial` older than a few seconds → attempt to keep as-is or
  delete if unreadable).
- **Disk-space guard:** before opening each new segment, check free space on the
  base volume. Below a threshold (e.g. < 2 GB or < X%):
  - v1: stop recording for that camera, set a visible state (see §13) and log once;
    do **not** crash or block live view.
  - future: prune-oldest-first beyond just the retention window.
- **I/O isolation:** all writer calls on the per-camera serial queue;
  `expectsMediaDataInRealTime = true`. The demux thread only does a non-blocking
  `queue.async` hand-off. A slow/full disk can never stall demux or display.

## 12. Retention / pruning

- `RecordingStore` runs a timer (every ~10 min, plus once at launch).
- Walk `{base}`; for each `.mp4`, determine its start time (parse from the
  filename; fall back to file mtime) and delete if `age > retentionHours`.
- **Never** delete the segment currently being written (track the active path per
  recorder) or any `.partial`.
- After deleting files, remove now-empty `HH → DD → YYYY-MM → camera` directories
  bottom-up.
- Pruning is I/O on a background queue; failures are logged, not fatal.

## 13. Status surfacing (optional but recommended)

- A small **● REC** indicator on recording tiles (reuse the tile overlay near the
  status dot / name), and/or a menu-bar item. Turns amber/stops on error
  (disk full, writer failure).
- Keeps the feature honest: the user can see at a glance that recording is live
  and healthy, not silently dead.

## 14. Storage math (call this out to the user)

Continuous recording is **large**. Per camera, per 48 h, by bitrate:

| Stream            | Bitrate | 60 s file | Per hour | 48 h    |
|-------------------|---------|-----------|----------|---------|
| Substream (low)   | 1 Mbps  | ~7.5 MB   | ~0.45 GB | ~22 GB  |
| Substream (typ.)  | 2 Mbps  | ~15 MB    | ~0.9 GB  | ~43 GB  |
| Main (typ.)       | 4 Mbps  | ~30 MB    | ~1.8 GB  | ~86 GB  |
| Main (high)       | 8 Mbps  | ~60 MB    | ~3.5 GB  | ~173 GB |

Six main-stream cameras @ 4 Mbps ≈ **~0.5 TB** for 48 h. **Recommendation:** point
recording-enabled cameras at their **substream** URL where available (most IP
cameras expose a second low-res endpoint), or shorten retention. A future “max
total size” cap is the natural follow-up.

## 15. Performance / latency safety (must-hold invariants)

- No new work on the demux thread beyond one `queue.async` hand-off per frame.
- No new work on the main thread; display enqueue path byte-for-byte unchanged.
- Recording append is passthrough (no decode/encode) — CPU cost is dominated by
  file I/O, absorbed by the OS write cache on the recorder queue.
- Adding PTS + sync flags to sample buffers does **not** change display: keep the
  `DisplayImmediately` attachment, which overrides PTS scheduling.

## 16. Alternatives considered

- **Alternative B — libavformat muxer in C (real PTS/DTS, or the `segment`
  muxer).** More faithful timing and a true remux, but pushes muxing onto the
  latency-critical demux thread, needs new C, and complicates Swift-side
  retention/UI. Higher risk. Revisit only if host-clock timing is insufficient
  (e.g. a camera turns out to use B-frames and playback timing suffers).
- **Alternative C — re-encode via `AVAssetWriter` with encoder settings.** Wastes
  CPU, loses quality, pointless when we already have compressed frames. Rejected.

## 17. Risks & open questions

- **R1 — B-frames.** If any camera uses B-frames, host-clock PTS ordering is
  wrong. *Mitigation:* verify with `ffprobe`/inspecting NAL slice types during
  bring-up; if found, fall back to Alternative B for that stream.
- **R2 — GOP length vs segment length.** Very long GOPs make segments overshoot
  60 s. Acceptable; documented. Could later request/expect a keyframe interval.
- **R3 — Disk exhaustion.** Covered by §11 guard; still the biggest real-world
  failure mode. Consider a global size cap in a fast follow.
- **R4 — Clock jumps.** Host clock is monotonic (`CMClockGetHostTimeClock` is
  mach_absolute_time based), so NTP/wall-clock adjustments don't corrupt PTS.
  Wall-clock is used only for *filenames*, computed once per segment.
- **R5 — Very high camera count × main stream** → CPU is fine (copy), but write
  bandwidth and disk fill are the limits. Surface via §13/§14.

**Decisions needed from you:**
1. Default base folder: `~/Movies/LocalVideo` OK, or elsewhere?
2. Container: `.mp4` (chosen) vs `.mov` — any preference? (`.mp4` is more portable.)
3. Should record-enabled-but-hidden cameras be allowed (record without a tile)?
   Spec assumes **yes** (§6).
4. Do you want the ● REC indicator + disk-full alerting in v1, or defer to v2?

## 18. Suggested phasing

- **Phase 1 — core capture:** parser timing/sync change; `CameraRecorder` with
  60 s keyframe-aligned segments + fragmented MP4; fixed default folder; one
  camera. Prove files play in QuickTime/VLC and timing looks right.
- **Phase 2 — config + UI:** `recordVideo` per camera, global settings block,
  Preferences switches + folder picker; multi-camera; stream-when-record rule.
- **Phase 3 — retention + robustness:** pruning timer, empty-dir cleanup, disk
  guard, clean-quit finalisation, `.partial` handling, REC indicator.
- **Phase 4 — polish (optional):** substream hint, max-size cap, startup sweep.

## 19. Effort estimate

**Moderate.** No new dependencies, no C changes, no threading redesign. The meat
is `CameraRecorder` (writer lifecycle + keyframe-aligned rotation + robust
finalisation) and the retention/robustness details; everything else (config, UI,
wiring) follows existing patterns closely. Rough order: Phase 1 small–medium,
Phases 2–3 medium, Phase 4 small.
