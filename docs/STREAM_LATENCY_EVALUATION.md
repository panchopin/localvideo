# Stream Latency Evaluation Plan

How to measure RTSP stream latency for LocalVideo **honestly** — measuring the right
pipeline, at the right precision, without touching the live viewer.

**Status:** Plan only — tooling not yet implemented. Native Swift, no Python.

---

## Three different questions (don't conflate them)

"Stream speed" is really three questions, each needing a different instrument. The
biggest mistake is using one tool (a stream-capturing probe) to answer all three.

| # | Question | Right instrument | Trustworthy? |
|---|----------|------------------|--------------|
| **Q1** | Is the stream healthy / has it regressed? (TCP-trap, buffer bloat, FPS collapse) | **Tool A** — drift + FPS on a direct capture | Yes — drift is robust to clock error |
| **Q2** | How does LocalVideo compare to another viewer (e.g. *IP Camera Viewer 2*)? | **Tool B** — simultaneous screen capture of both windows | Yes — relative, cancels clock error |
| **Q3** | What is the absolute glass-to-glass latency in ms? | **Tool B** + flip-edge, on the app's *rendered* output | Approximate (±~frame interval), bounded by OSD + NTP |

The primary deliverables are **Q1 (regression)** and **Q2 (comparison)** — both
trustworthy. Q3 is achievable to ~tens of ms with the flip-edge method, but a precise
absolute number is fundamentally limited (see [Accuracy ceiling](#accuracy-ceiling)).

---

## Two facts that dictate the whole design

1. **A probe that captures the stream measures the *probe's* pipeline, not the app's.**
   Decoding the RTSP stream in a separate process (ffmpeg/OpenCV/Swift) has its *own*
   buffering and decode cost — which we measured at ~0.5–1 s *worse* than the native
   `AVSampleBufferDisplayLayer` path. So **probe-absolute-lag says nothing about the
   app's latency.** To measure the app, you must observe **what the app renders on
   screen** (screen capture), not a fresh independent decode.

2. **The OSD clock is second-resolution.** Cameras burn `HH:MM:SS` into the frame. Read
   naïvely that is ±0.5 s — useless against a ~200 ms target, and `mean/p50/p95` of it is
   false precision. Sub-second requires the **flip-edge** technique (detect the frame
   where the seconds digit *increments*; at that instant camera-time is exactly an
   integer second; resolution then equals your capture interval, ~16–33 ms), which needs
   **frame-rate sampling and frame timing** — the opposite of sparse 1 Hz sampling.

Everything below follows from these two facts.

---

## Method primitives

### M1 — Drift (for Q1, regression)
Sample the stream at ~1 Hz; per sample compute `delta = T_local − T_osd`. The **absolute
value is coarse and ignored**; the **slope of delta over 60 s is the signal**. Flat =
healthy; monotonically increasing = buffer accumulation / TCP-trap = FAIL. Drift is
robust to both clock-sync error and OSD quantization (a constant offset cancels in a
slope). For drift you don't even need OCR — pixel-change detection on the OSD ROI to
timestamp each second-flip is more robust than reading digits.

### M2 — Simultaneous differential (for Q2, the comparison you actually care about)
Show the **same camera** in LocalVideo *and* the reference viewer at once. Capture **both
windows in a single screen frame**, repeatedly, at high rate. Detect each window's
OSD second-flip; the difference in *local* wall-time between the two flips = **relative
latency between the viewers**, to ~frame resolution. Because both observe the same camera
clock, **camera NTP error cancels exactly** — this is the rigorous version of your
earlier "it's ~1 s behind" eyeball test.
*Constraint:* needs the camera to allow two simultaneous clients. If it allows only one,
fall back to sequential A/B (M3), which reintroduces clock-sync error.

### M3 — Flip-edge absolute (for Q3, best-effort absolute)
Screen-capture **the app's rendered tile** at the display frame rate. Detect the OSD
second-flip; `latency ≈ T_local(flip frame) − T_osd_integer_second`. Resolution = capture
interval. This measures true camera→screen glass-to-glass for the app, bounded below by
the OSD resolution trick and the camera/Mac NTP offset.

---

## The two tools

### Tool A — Health & regression probe  (answers Q1)
- **Input:** direct RTSP capture via `ffmpeg` (same flags as production:
  `rtsp_transport=tcp`, `fflags=nobuffer`, `flags=low_delay`), 1 frame/s.
- **Does NOT touch** `RTSPSource` / `AVSampleBufferDisplayLayer`. Runs as a separate
  Swift CLI; the app stays zero-copy.
- **Metrics:** drift slope (M1), sustained FPS, OCR/flip success rate.
- **Absolute lag:** reported only as a coarse bucket ("~0.5 s / ~1 s / growing"), never
  as precise ms.
- **Use:** run after any engine/config change; always include the TCP-forced camera.

### Tool B — App latency & comparison  (answers Q2 + Q3)
- **Input:** **ScreenCaptureKit** capture of the LocalVideo window (and the reference
  app's window) — i.e. the *rendered* output, the only thing that reflects the app's real
  latency.
- **Q2 (relative):** simultaneous dual-window capture + flip-edge on each (M2).
- **Q3 (absolute):** flip-edge on the app's tile vs local clock (M3).
- **Use:** the headline "how fast is our stream, and vs the reference" answer.

---

## Why not the gold standard

The most accurate glass-to-glass method is to point a camera at an on-screen
**millisecond** timer and recapture both — zero clock-sync error, ms precision. It is
**impractical here**: the cameras are installed, pointed at real scenes, and can't see
your monitor. Hence Tool B (rendered-output + flip-edge) is the realistic best, and Q3
stays approximate by design.

---

## Architecture

```
Camera (OSD clock burned in)
   │
   ├─► LocalVideo app (UNCHANGED — never instrumented)
   │        ffmpeg demux → H264Parser → AVSampleBufferDisplayLayer
   │             │
   │             └─(its rendered window)─► Tool B: ScreenCaptureKit → ROI → Vision OCR
   │                                              → flip-edge vs local clock
   │
   └─► Tool A (sidecar, on demand)
            ffmpeg direct capture (TCP, low-delay) → 1 fps PNG
            → ROI → Vision OCR / pixel-flip → drift slope + FPS
```

All Swift. **Vision** (`VNRecognizeTextRequest`) for OCR — native, on-device, no deps.
**ScreenCaptureKit** for window capture (needs Screen Recording permission once).
`ffmpeg` (already a project dependency) for direct stream grabs. **No Python, no OpenCV**
— the repo is pure native Swift and stays that way.

---

## Pass / fail

| Check | Tool | PASS | FAIL |
|-------|------|------|------|
| Lag drift (60 s) | A | slope ≈ 0 (flat) | delta rises monotonically |
| FPS | A | sustained near camera rate | ~1 fps / frequent stalls |
| OSD readability | A/B | ≥ 80% flips detected | persistent miss (ROI/calibration) |
| Connect | A | starts within timeout | unreachable / auth error |
| App vs reference | B | LocalVideo ≤ reference (within noise) | LocalVideo clearly behind |

**Verdict format (terse):**
```
Verdict: PASS | FAIL | BLOCKED (+ one-line why)
Q1 per camera: fps, drift (flat/rising), coarse_lag_bucket
Q2/Q3 (if run): app_vs_reference_ms (relative), app_absolute_ms (±capture interval)
```
BLOCKED = camera offline / single-client / permission issue — environment, not a defect.

---

## ROI calibration

OSD position/size differs by model (v3 vs v4-smaller) and per install. Store fractional
crops (resolution-independent) per camera in `tools/latency-probe/rois.json`:

```json
{
  "camera-id": {
    "stream_roi": { "x_frac": 0.82, "y_frac": 0.88, "w_frac": 0.16, "h_frac": 0.10 },
    "screen_roi": { "x_frac": 0.82, "y_frac": 0.88, "w_frac": 0.16, "h_frac": 0.10 }
  }
}
```
`stream_roi` is for Tool A (raw frame); `screen_roi` is for Tool B (within the app's tile
rect, which the tool derives from the window/grid geometry). Calibrate once per model.

---

## Accuracy ceiling (state this plainly)

- **Trustworthy:** drift (Q1) and *relative* app-vs-reference (Q2) — clock error cancels.
- **Approximate:** absolute ms (Q3) — bounded by OSD second-resolution + flip-edge
  capture interval (~16–33 ms) + camera/Mac NTP offset (tens to hundreds of ms).
- **Not claimed:** millisecond-exact absolute latency. The second-granularity OSD cannot
  support it; do not report `p95 = 187 ms` as if it were real.

One-time sanity: confirm the camera OSD and Mac clock agree to within ~1 s, and that both
run NTP. A large offset invalidates Q3 (but not Q1/Q2).

---

## Tooling layout (Swift, no new deps)

```
native/
  Package.swift            # add a second executable target: "latency-probe"
  Sources/LatencyProbe/
    main.swift             # CLI: read cameras.json, run Tool A / Tool B
    StreamProbe.swift      # Tool A: ffmpeg 1fps capture → drift + FPS
    ScreenProbe.swift      # Tool B: ScreenCaptureKit → tile ROI → flip-edge
    OSDReader.swift        # Vision OCR + second-flip detection (shared)
  tools/latency-probe/rois.json
```
Reuses `Config`/`cameras.json` parsing and the production ffmpeg flags. **No changes to
the app's render path.**

---

## Credentials & safety

- Read `cameras.json` (dev: repo root; bundled: `~/Library/Application Support/LocalVideo/`).
- **Never** log resolved URLs (they contain passwords) or ffmpeg stderr.
- Tool B requires Screen Recording permission; prompt-and-Allow once.

---

## Test order (cheap → expensive)

1. **Static** — CLI builds, `cameras.json` parses, ffmpeg resolves.
2. **Connectivity + FPS** (Tool A) — 10 s headless capture, sustained fps, no GUI.
3. **Drift** (Tool A) — 60 s, slope check. Always include the TCP-forced camera.
4. **Comparison** (Tool B) — simultaneous dual-window flip-edge vs the reference viewer.
5. **Absolute** (Tool B) — flip-edge on the app's tile (report with explicit ± bound).

---

## Open questions

- Exact v3/v4 ROI fractions per installed camera (calibrate once → `rois.json`).
- Which cameras actually burn an OSD clock (skip OCR for those that don't).
- Dual-client support per camera (decides M2-simultaneous vs M3-sequential for Q2).
- ScreenCaptureKit window targeting for the reference app (match by bundle id / title).

---

## References

- Product latency goal and engine journey: `CLAUDE.md`, `STATUS.md`
- Production capture flags to mirror in Tool A: `native/.../RTSPSource.swift`
- QA report format / TCP-trap context: `.claude/skills/rtsp-qa/SKILL.md`
