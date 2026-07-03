# Feature Spec — Drag-to-Rearrange (swap camera tiles)

_Design spec for `rtsp-dev`. Design-focused; no engine code. Author: `rtsp-ux`._

## Summary

Let the user **click-drag a camera tile onto another tile to swap their positions**
in the grid. Works for any camera count. Example: in a 2-camera side-by-side layout,
dragging the left tile onto the right swaps them. The swap is **positional only** — it
reorders which camera occupies which grid cell; it never touches the stream, decode, or
connection. The new order **persists to `cameras.json`** so it survives relaunch.

## Why this shape

- The grid renders the `tiles` array **in order** (`GridContainerView.layout()` places
  `tiles[i]` at cell `i`). Visual position == array index. So a swap is just exchanging
  two elements of the model's ordered camera list and re-laying out.
- `AppDelegate` is the source of truth: `cameras: [CameraConfig]` (ordered) →
  `orderedTiles` → `grid.setTiles(...)`. Reorder `cameras`, rebuild `orderedTiles`,
  persist. **Do not** recreate tiles or restart `RTSPSource`s — moving a tile is free and
  must not disturb the live render.

## Interaction flow

1. **Mouse-down** on a tile (single click, `clickCount == 1`): arm a potential drag.
   Record the start point and the source tile. Do **not** start dragging yet.
2. **Mouse-dragged** past a threshold (**6 pt** of travel): begin the drag session.
   - Source tile dims to ~30% opacity (it stays in place as a "hole").
   - A **drag ghost** follows the cursor (see Visual feedback).
   - Cursor becomes the **closed hand** (`NSCursor.closedHand`) for the session.
3. **While dragging:** the tile currently under the cursor (if not the source) is the
   **drop target** and gets a highlight border. Only one target highlighted at a time.
4. **Mouse-up:**
   - Over a **different tile** → **swap** source and target in the model, persist, and
     re-lay out (with a short position animation, see below). Ghost disappears.
   - Over the **source itself**, over a gap, or **outside the grid** → **no-op**: ghost
     animates back to the source cell, source tile restores full opacity.
5. Drag is **cancelable**: pressing `Esc` mid-drag cancels (treated as no-op). Note: `Esc`
   otherwise quits the app — during an active drag it must be intercepted to cancel only.

## Visual feedback

**Drag ghost — do NOT snapshot the video.** The tiles are `AVSampleBufferDisplayLayer`
(hardware/IOSurface-backed); `cacheDisplay`/`bitmapImageRep` of them comes back **blank/
black** (same root cause as the Tool B window-capture issue). Instead the ghost is a
lightweight synthetic placeholder:

```
   ┌───────────────────────┐
   │                       │   • rounded-rect, dark fill  (NSColor(white:0.12,alpha:0.9))
   │      ▣  Front Door     │   • 2 pt accent border (NSColor.controlAccentColor)
   │                       │   • camera glyph + name, centered, white
   └───────────────────────┘   • whole ghost at ~85% opacity, ~0.6× the tile size
             ⌖ cursor            • follows cursor, centered on the pointer
```

- **Source tile:** dim to 30% opacity (`layer.opacity`) for the duration; a subtle inset
  border optional. It reads as "the slot being moved."
- **Drop target:** 3 pt inset highlight border in `controlAccentColor` and a ~0.98× scale
  nudge (optional). Clears the instant the cursor leaves it.
- **Return / settle animation:** on drop (swap or cancel), animate tile frames to their new
  positions over ~0.18 s ease-out (`CABasicAnimation`/`NSView` animator). Keep it short —
  the live video keeps rendering during the move.

**ASCII — a swap in a 2-cam layout:**

```
 before drag        dragging L→R           after drop (swapped)
 ┌────┬────┐        ┌────┬────┐            ┌────┬────┐
 │ A  │ B  │        │▓▓▓▓│[B ]│  ghost(A)  │ B  │ A  │
 │left│rght│        │dim │hi- │  ~~~~~▣A    │left│rght│
 └────┴────┘        └────┴lite┘            └────┴────┘
                    B highlighted as target
```

## Component choices (AppKit)

- Gesture: `CameraTileView` overrides `mouseDown/mouseDragged/mouseUp` (it already has a
  tracking area for hover). It reports drag intent to a delegate rather than mutating the
  model itself.
- Recommended: a lightweight **delegate/callback** from `CameraTileView` →
  `GridContainerView` → `AppDelegate` (e.g. `onReorderRequest(from:to:)`), OR a gesture
  coordinator owned by `GridContainerView` (it knows all tile frames, so hit-testing the
  drop target is a simple `tiles.first { $0.frame.contains(point) }`). **Prefer handling
  the drag in `GridContainerView`** — it owns tile geometry and can host the ghost layer.
- Ghost: a `CALayer` (or borderless child view) added to `GridContainerView`, not a real
  drag pasteboard session (`NSDraggingSession` is heavier and buys nothing here — this is
  an in-view reorder, not an inter-app drag).
- Highlight: toggle a `CALayer` border on the target tile's root layer.
- Persistence: reuse `AppDelegate.applyCameras(...)`/`persist()` path, or a narrower
  `reorderCameras(from:to:)` that swaps in `cameras`, rebuilds `orderedTiles`, calls
  `grid.setTiles`, and `persist()`. **Must be atomic and must not restart unchanged
  streams** (the existing diffed-apply already no-ops when URLs are unchanged, so a pure
  reorder restarts nothing — verify this holds).

## Interaction with existing UI

- **Kick (reconnect) button + name overlay:** both are subviews of the tile, so they move
  with it automatically on swap — no special handling. **During a drag**, suppress hover
  state so the kick button doesn't appear on the ghost/target (hide it for the drag
  duration; restore on drop).
- **Auto vs manual layout:** a swap changes **order only**, never `columns`. In auto mode
  the centered-last-row math (`GridContainerView`) just reflects the new order. No layout-
  mode change.
- **Status dots / reconnect:** unaffected — swapping moves the whole tile including its
  current status; the stream underneath keeps running.

## Edge cases

| Case | Behavior |
|------|----------|
| Drag onto self | No-op; ghost returns to origin. |
| Drop in a gap / outside the grid | No-op; ghost returns. |
| Single camera | No valid target exists; drag is a no-op (optionally don't even arm it when `tiles.count < 2`). |
| Drag during reconnect/connecting/failed | Allowed — position is independent of stream state; the tile (in whatever visual state) just moves. |
| Partial last row (e.g. 3 cams, 2-over-1) | Swap by array index still works; re-layout recomputes the centered row. |
| Window resize mid-drag | Re-hit-test against current frames; ghost keeps following cursor. |
| Rapid double-click | Must NOT arm a drag (that's the enlarge gesture — see the double-click spec). Drag only begins after the 6 pt move threshold, which a double-click won't cross. |

## Persistence

**Yes — persist.** Reorder `cameras` and write `cameras.json` atomically (existing
`Config.save`). Order in the file is the restore order. Never write `resolvedURL` / never
echo credentials (existing save path already handles this).

## Open product decisions (flag to user)

1. **Swap vs insert-shift.** Spec above is **swap** (A↔B), per the request. An alternative
   is "pull out and insert, shifting the rest" (like reordering a list). Swap is simpler and
   matches the ask; noting the alternative exists.
2. **`Esc` during drag.** Recommended to intercept `Esc` to cancel the drag instead of
   quitting. Confirm that's acceptable (it's a safer default than quitting mid-gesture).
