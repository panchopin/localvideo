# Feature Spec — "Show video stream" per-camera toggle

_Design spec for `rtsp-dev`. Design-focused; no engine code. Author: `rtsp-ux`._

## Summary

Add a per-camera boolean **"Show video stream"** (default **true**), editable via a checkbox
in the Preferences edit form. When **false**, the app does **not connect/stream** that camera
and does **not** render a tile for it — the main grid **adapts** to show only the enabled
cameras. Preferences keeps listing **all** cameras (so any can be toggled back on). The flag
**persists** in `cameras.json` and is **backward-compatible** (absent ⇒ shown).

This lets a user keep a camera *configured* (URL + credentials preserved) but *not shown* —
to declutter the grid or stop pulling a stream they don't want right now — without deleting it.

## Why this shape

- The grid renders whatever tile array it's handed (`GridContainerView` adapts to
  `tiles.count` + `columns`). So "hide a camera" = don't build a tile/stream for it, and the
  grid re-lays out automatically. No engine or grid change.
- `AppDelegate.cameras` stays the **full** list (source of truth, persisted, shown in
  Preferences). The app derives the **shown** subset (`showVideoStream == true`) and drives
  streams + tiles + layout off that subset.
- "Don't stream it" is literal: a hidden camera gets **no `RTSPSource`** — no connection, no
  CPU, no bandwidth — not just a hidden tile.

## The control (Preferences edit form)

A single **checkbox** (`NSButton`, `setButtonType(.switch)`) titled **"Show video stream"**,
placed **below the Password field**. The error label shifts down to make room.

```
 Edit Camera
 ┌───────────────────────────────────────────────┐
 │ Name      [ Front Door                       ] │
 │ URL       [ rtsp://192.168.0.10:554/live     ] │
 │ Username  [ admin                            ] │
 │ Password  [ ••••••••                         ] │
 │                                                │
 │ ☑ Show video stream        ← new checkbox      │
 │                                                │
 │ (validation error text appears here)           │
 │                                    [  Save  ]   │
 └───────────────────────────────────────────────┘
```

- **Checked** = shown (streams in the grid). **Unchecked** = hidden (not streamed).
- **Applied on Save**, like every other field — **no live-toggle action** on the checkbox.
  (A live toggle would re-run Name/URL validation on a half-edited row and could trip an
  error; keeping it on Save matches the existing form model.)
- Default for a newly added or discovered camera: **checked** (the `Bool` defaults to true).
- `populateForm` sets the checkbox from `cam.showVideoStream`; `setFormEnabled` includes it in
  the enable/disable set; `saveForm` reads `checkbox.state == .on` into the saved
  `CameraConfig`.

## Indicating hidden cameras in the list

The Preferences camera list (left table) still shows **all** cameras. A hidden camera reads as
"off":

- Its **name is dimmed** (`.secondaryLabelColor`) instead of the normal label color.
- Its status dot is naturally **gray** (a hidden camera has no stream/status), which already
  reads as inactive.

```
 Cameras
 ┌────────────────────────┐
 │ ● Front Door           │   ← shown (green dot, normal text)
 │ ● Backyard             │   ← shown
 │ ○ Garage   (dimmed)    │   ← hidden (gray dot, dimmed text)
 │ ● Driveway             │
 └────────────────────────┘
```

## Grid adaptation

- Only cameras with `showVideoStream == true` get a tile + stream. The grid lays out that
  count: **6 configured, 4 enabled → the grid shows 4** (auto columns = `autoColumns(4)` = 2).
- Toggling a camera **off** removes its tile and stops its stream; the remaining tiles reflow.
  Toggling **on** starts its stream and adds a tile; the grid reflows. Neither disturbs the
  other cameras' live streams.

## Interaction with existing features

- **Drag-to-swap:** unaffected and must keep working when hidden cameras are interspersed in
  the full list. The swap is **by identity** — dragging shown tile A onto shown tile C swaps
  their positions in the full camera order, leaving any hidden camera between them in place.
  (e.g. full `[A, B(hidden), C]`, shown `[A, C]`; swap → full `[C, B(hidden), A]`, shown
  `[C, A]`.)
- **Double-click enlarge (solo):** if the soloed camera is **hidden via Preferences**, the app
  **exits solo** and returns to the grid (never leave a solo pointing at a gone tile). Solo of
  a shown camera is unaffected.
- **`0` / `1`–`6` layout keys:** operate on the shown grid as before (`0` auto uses the shown
  count; manual columns clamp to the shown tile count).

## States

- **Some hidden:** grid shows the enabled subset; Preferences lists all.
- **All cameras hidden** (cameras configured, none shown): the grid is **hidden** and a
  **distinct empty message** appears — e.g. *"All cameras are hidden.\nEnable one in
  Preferences (⌘,)."* — so an all-hidden window isn't just a confusing black rectangle. This is
  different from the **no cameras configured** message (*"No cameras configured. Press ⌘, to
  add one."*), which also auto-opens Preferences on launch. An all-hidden config does **not**
  force-open Preferences (the user may have intentionally hidden all).
- **Connecting / failed:** unchanged for shown cameras. Hidden cameras have no status.

## Persistence & backward-compatibility

- JSON key: **`showVideoStream`** (Bool), **always encoded** so it round-trips.
- **Backward-compatible read:** an existing `cameras.json` with no `showVideoStream` key ⇒ the
  camera is **shown** (decode defaults to `true`, mirroring how `id` defaults). The first save
  after upgrade writes the key for every camera.
- Writes remain atomic via the existing `Config.save`; never echo credentials.

## Edge cases

| Case | Behavior |
|------|----------|
| All cameras hidden | Grid hidden + distinct "all hidden" message; Preferences still lists all. |
| Toggle the soloed camera off | Exit solo, return to the grid. |
| Drag-swap with hidden cameras between shown ones | Swap by identity in the full order; hidden cameras keep their relative slots. |
| Edit a hidden camera's name/URL | Allowed; applied on Save (no tile to restart). Used when it's later toggled on. |
| Toggle a camera on | Starts its stream fresh with its current URL; tile added; grid reflows. |
| Max cameras | The `maxCameras` (9) cap counts the **full** list (shown + hidden), not just shown — you can configure up to 9 total. The Add button disables at 9 configured. |
| Old `cameras.json` (no key) | All cameras shown (default true). |

## Open product decisions (flag to user)

1. **Apply-on-Save vs live toggle.** Spec applies the flag on **Save** (consistent, avoids
   validation trip on a half-edited row). A future "instant toggle" could be a separate
   affordance (e.g. a checkbox directly in the list row) that mutates only `showVideoStream`
   and re-applies without URL validation — noted, not built here.
2. **Hidden-row treatment.** Spec dims the name + relies on the gray dot. An alternative is an
   explicit "(hidden)" suffix or an eye-slash glyph — dimming is the lightest touch.
