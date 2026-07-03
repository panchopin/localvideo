# Feature Spec — Double-Click to Enlarge (solo tile)

_Design spec for `rtsp-dev`. Design-focused; no engine code. Author: `rtsp-ux`._

## Summary

**Double-click a camera tile to enlarge it to a solo 1×1 view** filling the grid area.
**Double-click again to return** to the previous all-cameras layout. It's a transient
**view state** (a "solo/zoom" mode), not a config change — it does not persist and does not
touch the stream.

## Why this shape

- Enlarge = show **only the chosen tile**, sized to the full grid bounds; hide the others.
  The chosen tile's `RTSPSource` keeps running; the hidden tiles' streams also keep running
  (no teardown — re-entering the grid must be instant, and tearing down/reconnecting would
  add latency and a black flash). Hidden tiles are just `isHidden = true`.
- This is a new **layout state** alongside the existing `.auto` / `.manual(n)` modes. Model
  it as a `solo: UUID?` (the enlarged camera) that, when set, overrides column layout.

## Interaction flow

1. **Double-click** (`mouseDown` with `event.clickCount == 2`) on tile X:
   - If not currently solo → **enter solo**: remember the current `layoutMode`, set
     `solo = X.id`, hide all other tiles, lay X out to full bounds.
2. **Double-click again** (on the solo tile) → **exit solo**: clear `solo`, unhide all
   tiles, restore the remembered `layoutMode`, re-lay out the grid.
3. The gesture **toggles**. Only the solo'd tile is visible to receive the second
   double-click, so "double-click again" naturally lands on it.

## Distinguishing from drag (critical)

Both gestures start with `mouseDown` on a tile. Disambiguate by:
- `event.clickCount == 2` → **enlarge toggle** (handle on mouse-down).
- `clickCount == 1` + drag past the 6 pt threshold → **drag-to-swap** (see that spec).
- `clickCount == 1` with no drag (a plain single click) → nothing (reserved; today a tile
  has no single-click action besides the hover kick button).

A double-click never moves 6 pt, so it can't accidentally arm a drag.

## Visual

```
   grid (4 cams)                 double-click B          double-click B again
 ┌─────┬─────┐                 ┌───────────────┐        ┌─────┬─────┐
 │  A  │  B  │                 │               │        │  A  │  B  │
 ├─────┼─────┤   ──dbl-click── │       B       │ ──────►├─────┼─────┤
 │  C  │  D  │      on B       │   (solo 1×1)   │        │  C  │  D  │
 └─────┴─────┘                 └───────────────┘        └─────┴─────┘
                               A,C,D hidden (streams live)
```

- Solo tile fills the entire grid area (same insets/background as normal).
- **Name overlay + status dot + kick button** on the solo tile work exactly as in grid mode
  (hover still reveals the kick button). No new chrome.
- Optional **transition:** a quick ~0.18 s frame animation of the tile growing to full
  bounds (and shrinking back). Keep subtle; never delay the video. If animation adds any
  risk, a hard cut is acceptable — enlarge must feel instant.
- Consider a brief, auto-fading hint the first time (e.g. "Double-click to exit") — optional,
  low priority; don't build permanent chrome.

## Interaction with the 1–6 / 0 keyboard shortcuts

The layout keys are **authoritative and exit solo**:

- While solo, pressing **`0`** (auto) or **`1`–`6`** (manual columns) → **exit solo** and
  apply that layout to the full grid. (You're explicitly asking for a grid, so give them
  one.)
- Entering solo **remembers** the pre-solo `layoutMode`; exiting via a second double-click
  restores it. Exiting via a layout key applies the *new* requested layout instead.
- `F` (fullscreen) is orthogonal — it toggles the macOS window; solo can coexist with
  fullscreen (a solo tile in a fullscreen window is the "one camera, maximized" view). No
  special handling needed.
- `Q` / `Esc` keep their current meaning (quit). **Do not** overload `Esc` to exit solo —
  `Esc`=quit is established and overloading a destructive key is risky. Exit is via
  double-click or a layout key. _(Flagged as a decision below.)_

## Component choices (AppKit)

- `CameraTileView.mouseDown`: branch on `event.clickCount`. On `== 2`, fire a delegate
  callback `onToggleSolo(self)` up to `GridContainerView`/`AppDelegate`. Keep the model
  logic out of the tile.
- `GridContainerView`: add `var soloTile: CameraTileView?` (or a solo id). `layout()` gets a
  short-circuit: if `soloTile` is set, that tile = full `bounds`, all others `isHidden`.
  On exit, unhide and fall through to the normal grid math. This keeps all geometry in one
  place.
- `AppDelegate`: owns whether we're solo (so keyboard handlers can exit it) and the
  remembered `layoutMode`. The `0`/`1`–`6` handlers call "exit solo (if any)" before/at
  applying the layout.

## Edge cases

| Case | Behavior |
|------|----------|
| Single camera | Double-click enlarges (already full) / returns — state toggles, no visible change. Harmless; allow it. |
| Solo'd camera removed via Preferences | Exit solo automatically (fall back to grid) — never leave a solo pointing at a gone tile. |
| Camera added/edited while solo | Stay solo on the current camera; apply the model change underneath. Re-enter grid to see changes, or the removal rule above fires. |
| Double-click during connecting/failed | Allowed — enlarge shows the large connecting/failed state; kick button still works to reconnect. |
| Enter solo, then drag | Dragging is a no-op in solo (only one visible tile; nothing to swap). |
| Window resize while solo | Solo tile tracks full bounds via `layout()`. |
| Reconnect fires while solo | Unaffected — stream state is independent of the solo view state. |

## Persistence

**No.** Solo/enlarge is transient view state. Not written to `cameras.json`. App relaunch
starts in the grid with the persisted order.

## Open product decisions (flag to user)

1. **`Esc` to exit solo.** Spec keeps `Esc`=quit and exits solo via double-click / layout
   key. If you'd rather `Esc` exit solo first (and only quit from the grid), that's a small
   change — confirm preference.
2. **Which layout to restore on exit.** Spec restores the exact pre-solo `layoutMode`.
   Alternative: always restore to `.auto`. Pre-solo restore is the least surprising.
