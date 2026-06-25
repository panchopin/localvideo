# CPU Optimization Plan — LocalVideo

> **Outcome (2026-06-25):** Measured, not guessed. Steady-state CPU is **~6%**
> (release *and* debug; VideoToolbox decodes on dedicated hardware). The observed
> **~150% was not the pipeline** — it was **ffmpeg demuxers accumulating across
> sessions** (21 orphans found at session start, incl. a camera no longer in
> config). Orphans survive only when an ffmpeg is stuck connecting/stalled and the
> parent dies abnormally (it never writes → never hits EPIPE → never gets reaped).
> Could not reproduce 150% via steady-state, debug build, reconnect churn, stalls,
> or crash/kill. **Fix shipped: ffmpeg lifecycle hardening** (startup orphan sweep,
> SIGINT/SIGTERM/SIGHUP teardown, SIGKILL fallback for stalled demuxers) —
> latency-irrelevant, no pipeline changes. The parser/sample-buffer micro-opts
> below were **deliberately skipped** (they'd shave fractions of a 6% baseline
> while touching the latency-critical path — pure risk for no measurable gain).
> Verified by a 5-test QA battery (orphan sweep, signal teardown, real-camera
> non-regression, CPU unchanged at 5.8%, no accumulation under churn) — all PASS.
> Harness: `tools/measure_cpu.sh`. Work landed on local branch `cpu-opt`.
>
> The analysis below is kept for reference / future scaling (e.g. 6+ cameras).



_Goal: reduce sustained CPU (currently ~150%) without regressing the achieved glass-to-glass
latency. Latency is still the product — every change here is evaluated first against
"does this add latency?" and only kept if the answer is no (or negligible)._

---

## Where the CPU actually goes

Per camera, the pipeline is: `ffmpeg` (RTSP demux, `-c:v copy`, no decode) → `H264Parser`
(Annex-B → `CMSampleBuffer`) → `AVSampleBufferDisplayLayer` (VideoToolbox HW decode + GPU
render). With up to 6 cameras at **1080p/1440p, 20 fps**, the cost stacks up in four places:

| Sink | Why it costs | Rough share* |
|------|--------------|--------------|
| **`H264Parser` (Swift)** | Re-copies and re-scans the whole accumulator buffer on every pipe read; double-copies each NAL into CoreMedia. Pure CPU, on the main-thread-adjacent hot path. | **High** |
| **VideoToolbox decode** | HW decode is cheap per pixel but we decode **full sensor resolution** (1440p) even though each tile renders at a fraction of that. ×6 streams ×20 fps. | **High** |
| **6× `ffmpeg` demux** | One subprocess per camera. Demux-only is light, but TLS (RTSPS) + TCP reassembly + 6 process scheduling adds up. | Medium |
| **Render / compositing** | `resizeAspect` scaling of 6 large layers; redundant work when occluded/minimized. | Low–Medium |

\* Shares are estimates to prioritize, not measurements. **Step 0 is to measure** before
changing anything (see below).

The two biggest wins are: (A) **fix the `H264Parser`** (pure code, zero latency risk,
arguably a latency *win*), and (B) **decode lower-resolution substreams for the grid**
(heuristic, the single largest decode/render saving).

---

## Step 0 — Measure first (don't guess)

Before any change, attribute the 150%:

1. **Per-process split:** `sample LocalVideoNative` (or Instruments → Time Profiler) to see
   how much is the app process vs. the 6 `ffmpeg` children. In Activity Monitor, expand the
   app to see child `ffmpeg` CPU individually.
2. **Within the app:** Instruments Time Profiler. Expect `H264Parser.drainCompleteNALs` /
   `Array(buffer)` / `removeSubrange` and CoreMedia block-buffer copies to dominate the
   app's own CPU.
3. **Decode cost:** toggle cameras 1→6 and watch CPU scale. If it scales ~linearly with
   pixel throughput, substreams (B) is the lever.

Record the baseline in `STATUS.md` so each optimization can be checked against it.

---

## A. Code optimizations (no latency risk)

### A1. Rewrite `H264Parser` to stop copying the whole buffer — **highest-value code fix**

`H264Parser.drainCompleteNALs()` currently, **on every pipe-read callback**:

- `let bytes = [UInt8](buffer)` — copies the *entire* accumulated buffer into a fresh Swift
  array. As the buffer grows toward a full keyframe (tens to hundreds of KB at 1440p), this
  is an O(n) copy **repeated for every partial read**.
- Re-scans from index 0 every time, so already-scanned bytes are walked again and again.
- `buffer.removeSubrange(0..<consumedUpTo)` — another O(n) memmove of the leftover.

This is quadratic-ish behavior on the hottest path in the app, ×6 cameras. Fixes:

1. **Don't materialize `[UInt8](buffer)`.** Scan `Data` (or a raw pointer via
   `withUnsafeBytes`) directly. Avoid the per-callback full-buffer Array allocation entirely.
2. **Track a persistent scan offset.** Keep an index of "scanned up to here" so each new
   read only scans the newly appended bytes (minus a 3-byte overlap for start codes split
   across reads). No re-walking old bytes.
3. **Compact instead of `removeSubrange` per call.** Maintain a read cursor into the buffer
   and only compact (drop consumed prefix) when the cursor passes a threshold (e.g. half the
   buffer), so memmoves are amortized, not per-read.
4. **Use `memchr`-style scanning for the `00 00 01` start code** rather than a Swift
   bounds-checked `bytes[i]` loop. Scanning for `0x01` and checking the two preceding bytes
   is far faster than byte-by-byte triple-compare with ARC/bounds overhead.

Expected: large reduction in the app's own CPU, **and** lower latency (less time between
bytes arriving and the frame being enqueued). This is the first thing to do.

### A2. Single-copy `CMSampleBuffer` construction

`makeSampleBuffer` builds an intermediate `avcc` `[UInt8]` (copy 1: NAL → array with length
prefix), then `CMBlockBufferCreateWithMemoryBlock(memoryBlock: nil, …)` allocates a block,
then `CMBlockBufferReplaceDataBytes` copies the array into it (copy 2).

Collapse to one copy:

- Allocate the `CMBlockBuffer` of size `nal.count + 4` up front, get its mutable pointer via
  `CMBlockBufferGetDataPointer`, write the 4-byte big-endian length prefix and `memcpy` the
  NAL bytes straight in. Eliminates the intermediate Swift array and one full copy per frame.
- Avoid the per-NAL `Array(bytes[start..<end])` slice→array in `handleNAL`; pass a pointer +
  range so SPS/PPS/slice handling reads from the existing buffer.

Per-frame, ×20 fps ×6 = ~120 allocations/copies per second removed.

### A3. Trim per-frame main-thread overhead

In `makeSource`, every frame does `DispatchQueue.main.async { lastFrameAt[id] = Date(); … }`.
That's 120 `Date()` allocations + dictionary writes + main-queue hops per second.

- The freshness signal only needs ~1 Hz resolution (the health timer runs at 1 Hz). Update
  `lastFrameAt` with a coarse timestamp (e.g. `CACurrentMediaTime()` cached, or only write if
  >250 ms since last write) to cut the per-frame bookkeeping while keeping health detection
  intact.
- `enqueue` **must** stay on main (CALayer requirement), so keep that hop — but move the
  freshness write off the per-frame path or coalesce it.

### A4. Build with optimizations

Confirm the shipped app is built **release** (`swift build -c release` / `package.sh`).
A debug build of the byte-scanning parser is dramatically slower (no inlining, bounds checks
retained). Verify `package.sh` uses `-c release`; if profiling, profile the release binary.

---

## B. Heuristic optimizations (trade quality/coverage, not latency)

### B1. Use camera **substreams** for the grid — **highest-value heuristic**

Most IP cameras (incl. the Wyze bridge here) expose a **low-resolution substream** alongside
the main stream (e.g. `…/stream2`, `…/sub`, a lower-res path). Decoding a 640×360 substream
instead of 1440p is a **~10–16× pixel reduction** in decode + render cost, per camera.

Plan:
- Add an optional `substreamURL` (or `subPath`) to `CameraConfig`.
- **Grid view uses the substream; full-resolution main stream is used only when a tile is
  focused/fullscreen** (decode-on-demand swap). This is exactly how NVR/multicam apps keep
  6+ feeds cheap.
- Latency impact: **none to positive** — smaller frames decode faster.
- Discovery: the existing network scanner could probe common substream paths.

This is the single biggest CPU lever for the multi-camera case and should be designed in.

### B2. Render only what's visible

- **Occlusion / minimize:** when the window is minimized, fully occluded, or on another
  Space, stop enqueuing (and ideally pause/stop the source). AppKit gives
  `occlusionState` / `NSWindow.isVisible` / miniaturize notifications. No point decoding
  6 streams into a hidden window.
- **Focused/fullscreen single camera:** when one tile is fullscreened, pause decode for the
  hidden tiles (keep ffmpeg alive briefly so resume is instant, or fully stop for max
  savings).

### B3. Drop frames before decode when behind (optional, careful)

The render layer already drops frames when `!isReadyForMoreMediaData`, but **decode still
happens upstream**. For non-focused tiles we could decode at a reduced rate (e.g. every other
frame) — but H.264 inter-frame dependencies mean you can only safely drop non-reference
frames; with no B-frames here you'd drop P-frames and get artifacts until the next keyframe.
**Lower-effort and cleaner: prefer B1 (substream) over frame-dropping.** Only revisit this if
substreams aren't available on a camera.

### B4. Request a lower frame rate / GOP from the camera (if supported)

If a camera's substream can be configured (ONVIF/web UI) to 10–15 fps for the grid, that's a
linear decode saving with no client-side complexity. Out of band (camera config, not app
code) but worth documenting as a deployment recommendation.

---

## C. ffmpeg-side tuning (the 6 subprocesses)

The demux processes are already minimal (`-c:v copy`, `-an`). Small wins:

- **`-threads 1`** on each ffmpeg: demux/copy doesn't need multiple threads; prevents each
  child from spinning up a thread pool. Low risk, easy to test.
- **Confirm no decode is sneaking in.** `-c:v copy` is correct — verify no filter/scale is
  ever added (it isn't today). Keep it that way.
- **Longer term:** replacing 6 ffmpeg subprocesses with a single in-process RTSP demuxer
  (e.g. linking `libavformat` directly, or a native RTSP client) would remove process
  overhead and pipe copies — but it's a large change with latency risk and should only follow
  after A+B are exhausted and measured. **Not** a first move.

---

## Suggested order of execution

1. **Step 0** — profile, record baseline in `STATUS.md`.
2. **A1** — rewrite `H264Parser` (offset-tracked, no full-buffer copy). Biggest pure-code win, latency-positive.
3. **A2** — single-copy `CMSampleBuffer`.
4. **A4** — verify release build / profile release.
5. **B1** — substream support for the grid (biggest heuristic win; needs config + UI design).
6. **B2** — pause decode when occluded/minimized/fullscreen-single.
7. **A3** — coalesce per-frame freshness bookkeeping.
8. **C** — `-threads 1` on ffmpeg.
9. Re-measure after each; keep only what moves the number without adding latency.

## What NOT to do

- Don't reintroduce buffering, A/V sync, or look-ahead to "smooth" CPU — that trades the
  product (latency) for cosmetics.
- Don't add client-side downscaling of full-res frames as a CPU fix — you still pay the full
  decode. Use the camera's substream instead (B1).
- Don't start with the in-process-demuxer rewrite (C, longer term) — high effort, latency
  risk; do the cheap, safe wins first.
