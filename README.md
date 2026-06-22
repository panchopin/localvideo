# LocalVideo — Native Low-Latency RTSP Camera Viewer

A native macOS app for viewing local-network RTSP cameras with the **lowest possible
glass-to-glass latency**. Built to match (and match it does) a purpose-built native
viewer, by decoding on VideoToolbox and rendering straight on the GPU — zero frame copies
into any runtime.

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
| **Native Swift: ffmpeg-demux → AVSampleBufferDisplayLayer** | **matches the reference ✓** |

**The lesson:** the last ~0.5s of latency is the cost of pulling decoded frames *into a
runtime* (OpenCV/Python copy + convert). No FFmpeg or OpenCV flag removes it — only a
native zero-copy path (hardware decode rendered directly on the GPU) does.

---

## Architecture

Per camera:

```
ffmpeg  (RTSP demux only — `-c:v copy`, no decode)
   → stdout pipe of compressed H.264 (tiny: ~Mbps, never a bottleneck)
   → H264Parser  (split Annex-B NALs, build CMVideoFormatDescription from SPS/PPS,
                  wrap slices as AVCC CMSampleBuffers tagged DisplayImmediately)
   → AVSampleBufferDisplayLayer  (VideoToolbox HW decode + zero-copy GPU render)
```

`ffmpeg` is used **only as a demuxer**. All latency-critical work (decode + display) is
native. It can later be replaced with in-process `libavformat` for a cleaner dependency —
same latency, since demux is not the bottleneck.

Source layout (`native/Sources/LocalVideoNative/`):

| File | Role |
|------|------|
| `RTSPSource.swift` | ffmpeg demux subprocess → parser; reports stream status |
| `H264Parser.swift` | Annex-B → `CMSampleBuffer` (the fiddly CoreMedia core) |
| `VideoLayerView.swift` | `AVSampleBufferDisplayLayer` host (the zero-copy render) |
| `GridContainerView.swift` / `CameraTileView.swift` | Grid + tile (video, name, status dot) |
| `PreferencesWindowController.swift` | Add/edit/delete cameras, network scan |
| `NetworkScanner.swift` / `DiscoverySheetController.swift` | RTSP subnet-sweep discovery |
| `Config.swift` | `cameras.json` (Codable, stable IDs, atomic save) |
| `main.swift` | App entry, window, menu bar, layout modes, diffed apply |

---

## Features

- **Auto-adaptive grid** — columns chosen from camera count (`⌈√N⌉`, wide row for 3); up
  to 9 cameras. Manual override with keys `1`–`6`; `0` returns to Auto.
- **Preferences panel** (`⌘,`) — add/edit/delete cameras without touching JSON. Saving
  only restarts a camera whose URL/credentials changed; healthy streams are never
  disturbed. Atomic writes; passwords masked.
- **Network discovery** — "Scan Network" sweeps the local `/24` for RTSP ports
  (554/8554), confirms with RTSP `OPTIONS`, and best-effort resolves the stream path via
  `DESCRIBE`. Lists only cameras not already configured.
- **Live status dots** — green = streaming, yellow = connecting, red = failed.
- **No audio, by design** — removes A/V sync overhead; latency is the product.

---

## Requirements

- macOS 13+ (Apple Silicon recommended), Xcode / Swift toolchain to build.
- **ffmpeg** installed (used as the demuxer): `brew install ffmpeg`. The app finds it at
  `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`.

---

## Build & run

```bash
# Build the double-clickable app bundle (release, ad-hoc signed, seeds config)
bash native/package.sh          # → native/build/LocalVideo.app
open native/build/LocalVideo.app

# Dev loop (reads the repo-relative cameras.json)
cd native && swift build && swift run LocalVideoNative ../cameras.json
```

The app icon is generated reproducibly by `native/make_icon.swift` → `Resources/AppIcon.icns`.

---

## Configuration

Cameras live in `cameras.json` (see `cameras.example.json` for the format):

```json
{
  "cameras": [
    { "name": "Front Door", "url": "rtsp://192.168.0.10:554/live" },
    { "name": "Backyard", "url": "rtsp://192.168.0.11:554/stream1",
      "username": "admin", "password": "secret" }
  ]
}
```

- `name`, `url` required; `username`/`password` optional (inserted after `rtsp://`).
- An `id` (UUID) is added automatically on first save — it gives each camera a stable
  identity so renaming/reordering never restarts a healthy stream.
- **Config location:** dev runs use the repo `cameras.json`; the **bundled app** uses
  `~/Library/Application Support/LocalVideo/cameras.json`.

Easiest path: launch the app and use **Preferences (`⌘,`)** — add cameras manually or via
**Scan Network**.

---

## Controls

| Input | Action |
|-------|--------|
| `1`–`6` | Lock the grid to N columns (manual) |
| `0` | Return to Auto layout |
| `F` / `⌃⌘F` | Toggle fullscreen |
| `Q` / `⌘Q` / `Esc` | Quit |
| `⌘,` | Open Preferences |

---

## Troubleshooting

- **Black tile / red status dot** — the camera is unreachable or its RTSP URL/path is
  wrong. Verify the stream independently: `ffplay -rtsp_transport tcp rtsp://…`.
- **"No cameras found" when scanning** — only *unmapped* cameras are listed; also, bare
  RTSP cameras with non-standard paths may need the path filled in manually after adding.
  Discovery uses an RTSP port sweep (not ONVIF/Bonjour), since many cameras are plain RTSP
  endpoints with no discovery protocol.
- **Local Network permission** — the network scan triggers the macOS prompt; click Allow.
- **Gatekeeper blocks the app** — it's ad-hoc signed (fine locally). On another Mac:
  right-click → Open the first time, or `xattr -dr com.apple.quarantine LocalVideo.app`.
  True distribution needs a Developer ID + notarization.
- **ffmpeg not found** — `brew install ffmpeg` (a partial Homebrew upgrade can also leave
  a broken `libx265` dylib; `brew reinstall ffmpeg` fixes it).

---

## Note on the Python viewer

`viewer.py` (OpenCV) and `viewer_vlc.py` (VLC) are **superseded** earlier engines, kept as
reference for the latency journey above. The native app in `native/` is the real product.
