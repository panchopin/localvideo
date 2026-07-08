# Feature Spec — Zoom In Place (per-tile digital zoom)

_Design spec for `rtsp-dev`. Design-focused; no engine code. Author: `rtsp-ux`._

## Summary

**Zoom into a camera's live feed inside its own tile bounds** — no popup, no enlarge, the
tile stays exactly where it is in the grid. Zoom with a **2-finger trackpad pinch**, a
**mouse horizontal scroll**, or **⇧ + scroll**. When zoomed in, **pan** to reframe (two-finger
scroll on a trackpad, or click-drag with a mouse). **Double-click resets** back to 1×.

It is transient **view state** (a "close-up"), like solo/enlarge: it does not persist and it
**never touches the stream**. Each tile zooms independently.

## Why this shape — and why it costs zero latency (read this first)

The video is rendered by an `AVSampleBufferDisplayLayer` (a `CALayer`) that fills the tile.
**Digital zoom = changing that layer's geometry (scale + offset).** The GPU compositor
already re-samples the layer every frame; scaling/translating it is free and happens off the
decode path entirely:

- We do **not** re-decode, re-scale in software, or copy any pixels. The `enqueue(sampleBuffer)`
  path in `VideoLayerView` is untouched — frames keep arriving and presenting `DisplayImmediately`.
- Zoom/pan only mutate `displayLayer.frame` (or its transform) between frames. This is the same
  class of operation as tile layout, which we already do on window resize with no latency cost.
- **Requirement:** wrap every geometry change in a `CATransaction` with
  `setDisableActions(true)` so Core Animation does **not** implicitly animate the zoom (an
  implicit 0.25 s animation would make the *picture* lag the stream — unacceptable). The zoom
  must be a hard, immediate geometry snap, frame to frame.

This is "digital zoom" (upscaling the received pixels), **not** optical or sensor zoom — we do
not ask the camera for a tighter crop, so there is no round-trip and no added latency. Zoomed-in
pixels get softer; that's expected and fine for a security-viewer "look closer" gesture.

## Where the state lives

Add zoom state to **`VideoLayerView`** (it owns `displayLayer` and its `layout()`), not to the
tile — keeps the gesture/geometry math in one place next to the layer it drives:

```
var zoomScale: CGFloat        // 1.0 … maxZoom (proposed max 6.0); 1.0 = normal
var zoomCenter: CGPoint       // normalized [0,1]²; the content point shown at view center
var isZoomed: Bool { zoomScale > 1.0 + epsilon }
func applyZoom(scaleDelta:aroundPointInView:)   // pinch / scroll → zoom about the pointer
func panBy(dxInView:dyInView:)                   // drag / two-finger scroll → move the frame
func resetZoom()                                 // → 1.0, center, hard snap
```

`CameraTileView` **captures** the gestures and forwards them to `tile.video`. The tile does not
own the math.

### Geometry model (for `rtsp-dev`)

In `VideoLayerView.layout()`, when `zoomScale > 1`:

1. `scaled = CGSize(bounds.w * zoomScale, bounds.h * zoomScale)`.
2. Position so the normalized `zoomCenter` maps to the view center:
   `origin.x = bounds.midX - zoomCenter.x * scaled.w` (same for y).
3. **Clamp** so the scaled frame always covers the tile — never reveal black gutters *beyond*
   the normal letterbox: `origin.x ∈ [bounds.w - scaled.w, 0]`, `origin.y ∈ [bounds.h - scaled.h, 0]`.
   Re-derive `zoomCenter` from the clamped origin so state and geometry stay consistent.
4. `displayLayer.frame = CGRect(origin, scaled)` inside a disabled-action `CATransaction`.

At `zoomScale == 1`, `displayLayer.frame = bounds` (today's behavior). **Zoom about the pointer**:
before applying a scale delta, record the content point under the cursor; after scaling, adjust
`zoomCenter` so that same content point stays under the cursor (standard focus-preserving zoom),
then clamp.

**Clipping:** the zoomed layer is larger than the tile, so it must be clipped to the tile or it
spills over neighbors. Set `masksToBounds = true` on `VideoLayerView`'s backing layer (the video
already fills the tile, so this has no normal-state effect).

**Overlays are unaffected:** the name label, status dot, and kick button are subviews of
`CameraTileView` (siblings of `VideoLayerView`), so they stay put and readable at any zoom —
good. They do not zoom with the picture.

## Interaction flow / input mapping

| Input | Device | Action |
|-------|--------|--------|
| **Pinch open / close** | Trackpad | Zoom in / out, centered on the gesture midpoint (`magnify(with:)`, use `event.magnification`) |
| **Horizontal scroll** | Mouse wheel | Zoom in / out, centered on the pointer |
| **⇧ + scroll** | Either | Zoom in / out, centered on the pointer |
| **Two-finger scroll (plain)** | Trackpad | **Pan** (only when zoomed; ignored at 1×) |
| **Plain vertical wheel** | Mouse | **Pan** vertically when zoomed; ignored at 1× |
| **Click-drag** | Mouse | **Pan** when zoomed; **drag-to-swap** when at 1× (see below) |
| **Double-click** | Either | **Reset to 1×** when zoomed; **solo/enlarge toggle** when at 1× |

Disambiguation rules (all handled in `CameraTileView`):

- `magnify(with:)` → always zoom.
- `scrollWheel(with:)` → **zoom** if `event.modifierFlags.contains(.shift)` OR the scroll is
  dominantly horizontal (`abs(scrollingDeltaX) > abs(scrollingDeltaY)`); otherwise **pan** (only
  if `isZoomed`, else pass through / ignore). On macOS ⇧+wheel already arrives as horizontal
  delta, so "horizontal scroll" and "⇧+scroll" collapse into the same branch — good.
- `mouseDragged` → if `video.isZoomed`, **pan** (`panBy(...)`) and do **not** arm a drag-to-swap;
  else fall through to today's swap-arming logic.
- `mouseDown` `clickCount == 2` → if `video.isZoomed`, `video.resetZoom()` and consume the event
  (do **not** toggle solo); else today's `tileRequestedSoloToggle`.

Scroll-to-zoom sensitivity: map `event.scrollingDeltaX` (points) to a multiplicative factor,
e.g. `factor = 1 + delta * k` with a small `k` (~0.01) and clamp per-event so a fast flick can't
jump the whole range. Pinch uses `1 + event.magnification` directly (already normalized).

## Visual

```
   tile at 1×                      pinch-open / ⇧-scroll           panned while zoomed
 ┌──────────────────┐             ┌──────────────────┐           ┌──────────────────┐
 │                  │             │    ┌────────┐    │           │████│         │    │
 │   (full frame)   │  ──zoom──►  │    │ 2.4×   │ ◄──┼─ crop     │████│  (crop  │    │
 │                  │             │    └────────┘    │  window   │████│ moves)  │    │
 │ ● Front Door     │             │ ● Front Door 2.4×│           │ ● Front Door 2.4×│
 └──────────────────┘             └──────────────────┘           └──────────────────┘
   layer.frame = bounds             layer scaled + clamped to tile; overlays stay put
```

### Zoom indicator (light chrome)

Show the current factor as a small badge (e.g. `2.4×`) so the state is legible and the reset
gesture is discoverable:

- Append `" 2.4×"` to the existing bottom-left name label while `isZoomed` (cheapest — reuses
  `nameLabel`, no new view), **or** a small standalone pill top-right that **auto-fades ~1 s**
  after the last zoom change. Recommend the name-label suffix for minimalism; pill if we want it
  more prominent. _(Flagged as a decision.)_
- Hide the indicator entirely at exactly 1× so a non-zoomed tile has zero extra chrome.

## Interaction with existing features

- **Solo / double-click enlarge:** zoom works in both grid and solo modes; it's per-tile and
  orthogonal. Double-click is overloaded safely: it *backs out the current close-up state* — if
  the tile is zoomed, it un-zooms; if it isn't, it toggles solo, exactly as today. A tile that is
  both solo'd and zoomed: first double-click un-zooms, second toggles solo out. Predictable.
- **Drag-to-swap:** unchanged at 1×. When zoomed, drag pans instead (you're framing the picture,
  not moving the tile). To swap a zoomed tile, double-click to reset first — acceptable and rare.
- **Layout keys `0` / `1`–`6`, `F` fullscreen:** orthogonal; they re-lay out tiles but must call
  `layout()` such that each tile re-applies its own zoom to the new size (clamp re-runs). Zoom
  state survives a resize/relayout. `F` fullscreen + zoom = a maximized, zoomed single view.
- **Reconnect / kick / auto-reconnect:** stream-level, independent of the view transform. A
  reconnect flushes the image but **keeps** the tile's zoom, so the camera comes back framed the
  same way. (Flagged: could argue reset-on-reconnect; keeping is less surprising.)

## Edge cases

| Case | Behavior |
|------|----------|
| Zoom out below 1× | Clamp to 1.0 (no "shrink below fit"); at 1.0, reset center, hide indicator. |
| Zoom in past max | Clamp to `maxZoom` (6×); further pinch/scroll is a no-op. |
| Pan at 1× | No-op (nothing to pan). Plain scroll/drag keep their 1× meaning. |
| Pan hits an edge | Clamp; the crop window stops at the content edge, never revealing gutters. |
| Window / grid resize while zoomed | `layout()` recomputes scaled frame from `zoomScale` + `zoomCenter` and re-clamps. Framing tracks the tile size. |
| Tile reordered (drag-swap) while another tile is zoomed | Zoom is tied to the `VideoLayerView`, which moves with its camera; framing is preserved. |
| Camera hidden/removed in Preferences | Tile is torn down; its zoom state goes with it. On re-show, starts at 1×. |
| Portrait / odd-aspect stream | Same math; clamp keeps the (already letterboxed) content covering the tile. |
| Very fast scroll flick | Per-event factor clamp prevents a single event from slamming to min/max. |

## Component choices (AppKit)

- **`VideoLayerView`** — owns `zoomScale`, `zoomCenter`, the clamped-geometry math in `layout()`,
  `applyZoom(scaleDelta:aroundPointInView:)`, `panBy(...)`, `resetZoom()`, and
  `masksToBounds = true`. All geometry writes inside `CATransaction { setDisableActions(true) }`.
- **`CameraTileView`** — override `magnify(with:)` and `scrollWheel(with:)`; branch `mouseDragged`
  and the `clickCount == 2` path on `video.isZoomed`. Convert `event.locationInWindow` into the
  video view's coords before forwarding (pointer-anchored zoom needs the local point). Update the
  zoom indicator (name-label suffix) when zoom changes. `acceptsTouchEvents`/gesture support:
  `magnify` works out of the box on `NSView` for trackpad pinch — no extra setup.
- **No `GridContainerView` change** for the core feature (geometry is per-tile). Only touch it if
  we add the optional menu items below.
- **Optional discoverability (HIG):** a **View ▸ Zoom** submenu — "Zoom In `⌘+`", "Zoom Out `⌘−`",
  "Actual Size `⌘0`" — acting on the **last-hovered** tile (track it like the kick-button hover
  already does). Makes the feature discoverable without a mouse gesture and follows the standard
  macOS zoom shortcuts. `⌘0` won't collide with the bare `0` = auto-layout key. _(Optional; flag.)_

## Persistence

**No.** Zoom is transient view state, like solo. Not written to `cameras.json`. App relaunch
starts every tile at 1×.

## Product decisions (resolved 2026-07-08)

1. **Reset gesture — DECIDED: double-click only.** Double-click a zoomed tile → reset to 1×
   (overloads the existing double-click-enlarge, which only runs at 1×). No reset key/menu.
2. **Zoom indicator — DECIDED: name-label suffix.** Append ` 2.4×` to the bottom-left name
   label while `isZoomed`; nothing at exactly 1×.
3. **Max zoom factor — DECIDED: 6×.**
4. **Zoom on auto-reconnect — DECIDED: keep framing** across a reconnect (less surprising).
5. **View ▸ Zoom menu items — DECIDED: not now.** Ship gesture-only (pinch / horizontal wheel /
   ⇧+scroll / drag-pan / double-click-reset). Menu + `⌘±/⌘0` can be added later.
```

