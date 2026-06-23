# Stream Latency Evaluation Plan

How to measure glass-to-glass lag for LocalVideo RTSP cameras without touching the
live viewer pipeline.

**Status:** Plan only — probe tooling not yet implemented.

---

## Goal

Measure whether each camera stream is **low-latency and stable**, and catch regressions
(TCP-stall trap, buffer bloat, FPS collapse) after engine or config changes.

Primary signal: **on-screen camera clock (OSD) vs local wall time.**

Secondary signals: **sustained FPS**, **lag drift over time**.

---

## Why OSD clock comparison

v3 and v4 cameras burn a clock into the bottom-right of every frame (v4 is smaller).
If the camera NTP sync is correct, that clock is a wall-time reference embedded in the
picture.

For each sampled frame:

```
lag ≈ T_received − T_camera_osd
```

| Term | Meaning |
|------|---------|
| `T_received` | Mac wall clock when the probe decoded/captured the frame |
| `T_camera_osd` | Time parsed from the OSD via OCR |

This measures end-to-end delay: capture → encode → network → demux → decode → sample.
Same family of method used for LED-clock and side-by-side viewer benchmarks.

**Resolution limit:** OSD typically updates once per second (`HH:MM:SS`). Expect
±0.5 s quantization even with perfect OCR. Good for “~0.5 s vs ~1 s vs growing lag”;
not for sub-100 ms tuning.

---

## Design principles

1. **Separate process** — never instrument `RTSPSource` / `AVSampleBufferDisplayLayer`.
   The probe uses its own ffmpeg/OpenCV capture path. LocalVideo stays zero-copy.

2. **Sparse sampling** — ~1 frame/s is enough for OCR; no need to record the full stream.

3. **No fixed-FPS math** — do not infer time from `frame_index / fps`. FPS drops and
   frame drops break that. Read the OSD on each sample.

4. **Measure drift, not just absolute lag** — a stable offset is acceptable; monotonically
   increasing lag over 60 s is a FAIL (buffer accumulation / TCP trap).

5. **Credentials** — read `cameras.json` but never log URLs with passwords or stderr
   from ffmpeg.

---

## Architecture

```
Camera (OSD clock burned in)
    │
    ├─► LocalVideo app (unchanged)
    │       ffmpeg demux → H264Parser → AVSampleBufferDisplayLayer
    │
    └─► Latency probe (sidecar, on demand)
            ffmpeg/OpenCV capture (TCP, low-delay flags)
            → crop bottom-right ROI
            → OCR (Vision / Tesseract)
            → log (T_received, T_camera, delta)
            → optional short annotated clip
```

The probe path is intentionally “slow” (decode in Python). That is fine — it must not
affect the product engine.

---

## Metrics

### 1. Lag (primary)

Per sample: `delta_ms = T_received − T_camera_osd` (handle midnight rollover).

Report over a run (default 60 s):

- mean, median (p50), p95
- **drift:** linear slope of delta over time (lag growing → FAIL)
- OCR success rate (require ≥ N consecutive good samples)

### 2. FPS (secondary)

Frame arrival rate in the probe over the same window.

- PASS: near the camera’s nominal rate (e.g. 15–30 fps depending on model)
- FAIL: sustained ~1 fps (TCP-stall trap) or long gaps

### 3. Differential vs reference (optional)

To compare **LocalVideo** vs *IP Camera Viewer 2* (original benchmark):

- Same stream, same probe ROI, two viewing conditions (A/B sequential if the camera
  allows only one client)
- Report **delta between viewers**, not absolute lag alone

Probe-only lag measures the **probe’s** decode path. Differential comparison isolates
the app under test.

---

## Pass / fail criteria

| Check | PASS | FAIL |
|-------|------|------|
| Lag stability (60 s) | delta flat within ~±1 s band | delta increases monotonically |
| FPS | sustained near camera rate | ~1 fps or frequent stalls |
| OCR | ≥ 80% samples readable | persistent OCR failure (ROI/config) |
| Connect | stream starts within timeout | unreachable / auth error |

**Verdict format (terse):**

```
Verdict: PASS | FAIL | BLOCKED (+ one-line why)
Per camera: lag_mean, lag_drift (yes/no), fps, ocr_ok%
```

BLOCKED = camera offline or environment issue, not a code defect.

---

## Probe procedure

### Prerequisites

- macOS, `ffmpeg` on PATH (same as the app)
- Python 3 + OpenCV (probe only; not part of the native app)
- `cameras.json` (dev: repo root; bundled app: `~/Library/Application Support/LocalVideo/cameras.json`)
- Mac clock NTP-synced
- One-time: verify camera OSD matches Mac time within ~1 s

### Per-camera calibration

v3 and v4 differ in OSD size and position. Store per-camera crop in a sidecar config
(e.g. `tools/latency_probe/rois.json`):

```json
{
  "camera-id-or-name": { "x_frac": 0.82, "y_frac": 0.88, "w_frac": 0.16, "h_frac": 0.10 }
}
```

Fractions are relative to frame width/height so resolution changes do not break ROI.

### Standard run (regression)

1. Start probe for each camera (or one named camera).
2. Duration: **60 s** default; sample interval: **1 s**.
3. Capture with same transport as production: `rtsp_transport=tcp`, `fflags=nobuffer`,
   `flags=low_delay`.
4. For each sample: grab frame → `T_received = now()` → crop ROI → OCR → compute delta.
5. Emit summary report (stdout + optional JSON).

### Debug run (evidence)

```bash
# Planned CLI shape — not implemented yet
python tools/latency_probe/probe.py --camera "Front Door" --duration 30 --record out.mp4
```

Burns `received_at=…` on saved frames for manual review when OCR disagrees with
eyeball check.

### TCP regression camera

Always include the camera that forces RTSP-over-TCP (blocks UDP) in the regression set.
That stream historically exposed the ~1 fps / lag-accumulation trap in VLC and lenient
demuxers. If its IP/path differs from docs, use the entry in your local `cameras.json`.

---

## What not to do

- Do not add buffering, queues, or timing machinery to the native render path for
  measurement.
- Do not use full-stream recording as the default — disk-heavy, no better than 1 Hz
  sampling for OSD lag.
- Do not trust sub-second lag claims from second-granularity OSD without a finer
  reference (e.g. millisecond test pattern).
- Do not log ffmpeg stderr (may contain credentials).

---

## Planned tooling layout

```
tools/latency_probe/
  probe.py           # CLI: read cameras.json, run samples, print report
  rois.json          # per-camera OSD crop (v3 / v4)
  requirements.txt   # opencv-python, etc. (probe-only deps)
```

No changes to `native/` required for v1.

---

## Test order (cheap → expensive)

1. **Static** — probe script imports, `cameras.json` parses, ffmpeg reachable.
2. **Connectivity + FPS** — 10 s headless capture, sustained fps, no GUI.
3. **OSD lag** — 60 s sample run, lag mean + drift check.
4. **Optional A/B** — differential vs reference viewer on the same camera.

---

## Open questions

- Exact v3/v4 ROI coordinates per installed camera (calibrate once, store in `rois.json`).
- Whether all cameras expose OSD clock (confirm per model; skip OCR for cameras without).
- Parallel RTSP clients: if a camera rejects dual connections, run probe and app
  sequentially for A/B tests.
- OCR engine choice: macOS Vision (no extra dep) vs Tesseract (more portable tuning).

---

## References

- Product latency goal and engine path: `CLAUDE.md`, `STATUS.md`
- Native capture flags (mirror in probe): `native/Sources/LocalVideoNative/RTSPSource.swift`
- QA skill (report format, TCP trap): `.claude/skills/rtsp-qa/SKILL.md`
