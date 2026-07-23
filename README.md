# LocalVideo — Native Low-Latency RTSP Camera Viewer

A native macOS app for viewing local-network RTSP cameras with the **lowest possible
glass-to-glass latency**. It matches a purpose-built native reference viewer by decoding
on VideoToolbox and rendering straight on the GPU — zero frame copies into any runtime —
and adds continuous recording (with optional audio) and self-updating.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-AppKit-orange)

---

## Why this exists

The goal was simple and uncompromising: a wall of local cameras with as little delay as
physically possible. Getting there meant trying — and discarding — several engines. The
table below is the short version, measured against a reference native viewer on the same
cameras:

| Engine | Result |
|--------|--------|
| VLC (`python-vlc`) | TCP-stall trap: ~1 FPS or runaway lag. Abandoned. |
| OpenCV/FFmpeg + threaded "latest frame" buffer | ~1s behind, tuned down to ~0.5s |
| OpenCV + low-latency FFmpeg flags + VideoToolbox HW decode | stuck at ~0.5s |
| Raw `ffplay` (low-latency flags) | *worse* (~1s) — its A/V sync clock adds delay |
| **Native Swift: libavformat-demux → AVSampleBufferDisplayLayer** | **matches the reference ✓** |

**The lesson:** the last ~0.5s of latency is the cost of pulling decoded frames *into a
runtime* (OpenCV/Python copy + convert). No FFmpeg or OpenCV flag removes it — only a
native zero-copy path (hardware decode rendered directly on the GPU) does.

---

## Architecture

Per camera:

```
CRTSPDemux   (in-process libavformat: connect RTSP, demux, NO decode)
   → Annex-B H.264 bytes  (compressed, ~Mbps — never a bottleneck)
   → H264Parser   (split NALs, build CMVideoFormatDescription from SPS/PPS,
                   wrap slices as AVCC CMSampleBuffers, host-clock PTS + sync flags)
   → AVSampleBufferDisplayLayer   (VideoToolbox HW decode + zero-copy GPU render)
```

Demuxing runs **in-process** via `libavformat` (the `CRTSPDemux` C target), not an
`ffmpeg` subprocess. Same latency (demux was never the bottleneck), and the camera URL —
which can embed a password — stays in this process's memory and never appears in any
process `argv` (can't leak via `ps`/Activity Monitor). All latency-critical work (decode +
display) is native.

Source layout:

| File | Role |
|------|------|
| `Sources/CRTSPDemux/` (C) | In-process libavformat RTSP(S) demuxer; emits Annex-B video + raw audio packets |
| `RTSPSource.swift` | Drives the demuxer on a background thread; fans frames to display + recorder |
| `H264Parser.swift` | Annex-B → `CMSampleBuffer` (monotonic host-clock PTS, keyframe/sync flags) |
| `VideoLayerView.swift` | `AVSampleBufferDisplayLayer` host — the zero-copy render (+ per-tile digital zoom) |
| `CameraTileView.swift` / `GridContainerView.swift` | Grid + tile: status/name overlay, drag-to-swap, double-click enlarge, expand/retract, reconnect |
| `CameraRecorder.swift` | Continuous recording (AVAssetWriter passthrough); optional G.711→PCM audio track |
| `RecordingStore.swift` | Recording folder layout, retention pruning, disk checks |
| `Audio.swift` | G.711 (A-law/µ-law) → 16-bit PCM decode; audio-stream config |
| `Updater.swift` | In-app updates from GitHub Releases (download, self-replace, relaunch) |
| `PreferencesWindowController.swift` | Add/edit/delete cameras, record toggles, recording settings, network scan |
| `NetworkScanner.swift` / `DiscoverySheetController.swift` | RTSP subnet-sweep discovery |
| `Config.swift` | `cameras.json` (Codable, stable IDs, atomic save, recording settings) |
| `main.swift` | App entry, window, menu bar, layout modes, diffed apply, recorder lifecycle, update checks |

---

## Features

**Viewing**
- **Auto-adaptive grid** — columns from camera count (`⌈√N⌉`, wide row for 3); up to 9
  cameras. Manual override with keys `1`–`6`; `0` returns to Auto.
- **Tile interactions** — drag-to-swap to reorder, double-click to enlarge one tile
  (solo) and back, an **expand/retract button** (4-arrow) on hover that does the same, and
  **pinch/scroll digital zoom** in place with pan.
- **Live status dots** — green = streaming, yellow = connecting, red = failed — with
  automatic reconnect on stalls and a manual reconnect button per tile.
- **Silent live view, by design** — audio is off in the live path to remove A/V-sync
  overhead; latency is the product. (Audio *can* be recorded — see below.)

**Recording** (opt-in per camera)
- **Continuous recording** to disk as **keyframe-aligned segments** (default 60s), a
  stream *copy* via `AVAssetWriter` passthrough — no re-encode, negligible CPU, and the
  live path is never touched. Fragmented MP4 so a crash still leaves a playable file.
- **Optional audio** — Wyze cams stream **G.711**, which MP4 can't hold, so audio
  recordings are decoded to **PCM** in-app and written as **`.mov`** (H.264 + PCM);
  video-only recordings stay `.mp4`.
- **Retention** — auto-deletes recordings older than a configurable window (default 48h)
  and prunes empty folders. Files are organized as
  `{folder}/{camera}/{YYYY-MM}/{DD}/{HH}/{camera}-{YYYYMMDD_HHMMSS}.{mp4|mov}`.
- ⚠️ Continuous recording is **large** (~tens of GB/camera/day at main-stream bitrates) —
  prefer a substream for recording where possible.

**App**
- **Preferences panel** (`⌘,`) — add/edit/delete cameras and the record toggles without
  touching JSON. Saving only restarts a camera whose URL/credentials changed; healthy
  streams are never disturbed. Atomic writes; passwords masked.
- **Network discovery** — "Scan Network" sweeps the local `/24` for RTSP ports (554/8554),
  confirms with RTSP `OPTIONS`, and best-effort resolves the path via `DESCRIBE`.
- **In-app updates** — checks GitHub Releases on launch (and on demand via **Check for
  Updates…**); downloads and self-installs a newer release, then relaunches.

---

## Requirements

- **To run the bundled app:** macOS 13+ (Apple Silicon). Nothing else — the `.app` is
  **self-contained** (the libav/ffmpeg dylibs are bundled into `Contents/Frameworks`).
- **To build:** the Swift/Xcode toolchain and **Homebrew ffmpeg** (`brew install ffmpeg`) —
  `package.sh` bundles its libav dylibs into the app so end users don't need Homebrew.

---

## Build & run

```bash
# Build the double-clickable, self-contained app bundle (release, ad-hoc signed)
bash native/package.sh          # → native/build/LocalVideo.app
open native/build/LocalVideo.app

# Dev loop (reads the repo-relative cameras.json)
cd native && swift build && swift run LocalVideoNative ../cameras.json
```

The app icon is generated reproducibly by `native/make_icon.swift` → `Resources/AppIcon.icns`.

---

## Configuration

Cameras live in `cameras.json` (see `cameras.example.json`):

```json
{
  "cameras": [
    { "name": "Front Door", "url": "rtsp://192.168.0.10:554/live" },
    { "name": "Backyard", "url": "rtsp://192.168.0.11:554/stream1",
      "username": "admin", "password": "secret",
      "recordVideo": true, "recordAudio": true }
  ],
  "recording": {
    "directory": "/Users/me/Movies/LocalVideo",
    "retentionHours": 48,
    "segmentSeconds": 60
  }
}
```

- `name`, `url` required; `username`/`password` optional (inserted after `rtsp://`).
- `showVideoStream` (default true) — when false the camera stays configured but isn't
  shown in the grid. `recordVideo` / `recordAudio` (default false) — record to disk; a
  camera streams whenever it's shown **or** recording, so you can record a hidden camera.
- The `recording` block is global (folder / retention / segment length); omitted keys fall
  back to defaults (`~/Movies/LocalVideo`, 48h, 60s).
- An `id` (UUID) is added automatically on first save — a stable identity so
  renaming/reordering never restarts a healthy stream.
- **Config location:** dev runs use the repo `cameras.json`; the **bundled app** uses
  `~/Library/Application Support/LocalVideo/cameras.json`.

Easiest path: launch the app and use **Preferences (`⌘,`)**.

---

## Controls

| Input | Action |
|-------|--------|
| Drag a tile onto another | Swap their positions |
| Double-click a tile | Enlarge to fill (solo); double-click again to restore |
| Expand/retract button (on hover) | Same as double-click |
| Pinch / ⇧-scroll on a tile | Digital zoom in place (drag to pan; double-click resets) |
| `1`–`6` | Lock the grid to N columns (manual) |
| `0` | Return to Auto layout |
| `F` / `⌃⌘F` | Toggle fullscreen |
| `Q` / `⌘Q` / `Esc` | Quit |
| `⌘,` | Open Preferences |

---

## Releases & updates

Releases are built by CI (`.github/workflows/release.yml`) on any `vX.Y.Z` tag: it builds
the self-contained `.app` on a macOS runner, zips it, and publishes it as a release asset.
The app's version is stamped from the tag. To cut a release:

```bash
git tag v0.5.0 && git push origin v0.5.0
```

The running app checks for a newer release on launch and via **Check for Updates…**, then
downloads and installs it in place. (An app with an older, pre-updater build must be
updated manually once from the [Releases page](https://github.com/panchopin/localvideo/releases).)

---

## Troubleshooting

- **Black tile / red status dot** — the camera is unreachable or its RTSP URL/path is
  wrong. Verify independently: `ffplay -rtsp_transport tcp rtsp://…`.
- **"No cameras found" when scanning** — only *unmapped* cameras are listed; bare RTSP
  cameras with non-standard paths may need the path filled in manually. Discovery is an
  RTSP port sweep (not ONVIF/Bonjour), since many cameras are plain RTSP endpoints.
- **Local Network permission** — the network scan triggers the macOS prompt; click Allow.
  After a self-update the ad-hoc signature changes, so this (and camera access) may
  re-prompt once.
- **No audio in a recording** — the camera has no audio stream, or it's a codec other than
  G.711 (only G.711 is wired). Video still records (as `.mp4`).
- **Gatekeeper blocks the app** — it's ad-hoc signed (fine locally). On another Mac:
  right-click → Open the first time, or `xattr -dr com.apple.quarantine LocalVideo.app`.
  True distribution needs a Developer ID + notarization.

---

## Note on earlier engines

This project passed through Python/OpenCV and VLC prototypes, and an `ffmpeg`-subprocess
demux, before the native in-process rewrite (see the journey table above). Those
prototypes have been removed — the native app in `native/` is the product. The lesson they
taught is preserved in this README.
