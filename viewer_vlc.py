#!/usr/bin/env python3
"""
LocalVideo — Lightweight RTSP Multi-Camera Viewer

A minimal, low-latency RTSP camera viewer for local networks.
Uses VLC for media playback (with hardware decoding) and PySide6 for the UI.

Architecture:
    - One shared vlc.Instance with low-latency tuning
    - Each camera gets a CameraWidget that embeds a VLC MediaPlayer
    - MainWindow manages the grid layout and audio selection
    - All cameras start muted; click one to hear its audio (others auto-mute)

Usage:
    uv run viewer.py

Configuration:
    Edit cameras.json to add/remove cameras. See README.md for format details.

Keyboard Shortcuts:
    1-6     Switch grid arrangement (rows × cols)
    F       Toggle fullscreen
    Q/Esc   Quit
"""

import json
import logging
import platform
import sys
from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

import vlc

# ---------------------------------------------------------------------------
# Logging — minimal, debug-only
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("localvideo")

# ---------------------------------------------------------------------------
# VLC instance configuration — shared across all cameras
# ---------------------------------------------------------------------------
# These flags are tuned for ultra-low-latency RTSP playback on a local network.
#
# VLC has MULTIPLE independent caching layers that stack up. ALL must be zeroed
# out to achieve true low latency. Setting only --network-caching is not enough.
#
# --- Caching (all zeroed) ---
# --network-caching=0       Network read buffer. Default 1000ms — the biggest knob.
# --live-caching=0           Additional buffer for live streams.
# --file-caching=0           File I/O buffer (not used for RTSP, zeroed for safety).
# --disc-caching=0           Disc I/O buffer (same).
# --sout-mux-caching=0       Muxer output buffer.
#
# --- Clock / Sync ---
# --clock-jitter=0           Disable clock jitter compensation (not needed on LAN).
# --clock-synchro=0          Disable stream clock synchronization. Without this,
#                            VLC tries to match the stream's PTS timestamps, which
#                            causes accumulated delay on live streams with imprecise
#                            clocks.
#
# --- Frame dropping ---
# --drop-late-frames         Drop frames that arrive too late to be displayed.
#                            Without this, late frames queue up → lag accumulates.
# --skip-frames              Allow the decoder to skip frames to keep up.
#
# --- Codec ---
# --avcodec-hw=videotoolbox  Hardware-accelerated decoding on macOS Apple Silicon.
# --avcodec-skiploopfilter=4  Skip H.264 deblocking filter (value 4 = skip all).
#                            Saves ~1-2ms per frame decode. Minor quality loss.
#
# --- Transport ---
# --rtsp-tcp                 Use TCP for RTSP. Reliable on LAN, avoids UDP packet
#                            loss artifacts. ~10-50ms penalty vs UDP.
#
# --- Misc ---
# --no-video-title-show      Suppress VLC's "now playing" overlay text.
# --no-stats                 Disable statistics collection.
# --verbose=1                Show warnings/errors for debugging.
VLC_ARGS = [
    "--verbose=1",
    "--no-stats",
    "--no-video-title-show",
    # Tiny buffer to absorb network jitter without causing huge lag
    "--network-caching=100",
    "--live-caching=100",
    "--file-caching=0",
    "--disc-caching=0",
    "--sout-mux-caching=0",
    # Frame dropping — critical for preventing lag accumulation
    "--drop-late-frames",
    "--skip-frames",
    "--avcodec-skiploopfilter=4",
    # Transport (Required because camera 2 / network blocks UDP)
    "--rtsp-tcp",
]


# ===========================================================================
# CameraWidget — A single camera view with embedded VLC player
# ===========================================================================
class CameraWidget(QFrame):
    """
    Embeds a VLC MediaPlayer inside a QFrame for a single RTSP stream.

    Layout:
        ┌─────────────────────────┐
        │                         │
        │   VLC renders here      │  ← _video_surface (QWidget with WA_NativeWindow)
        │   (native NSView)       │
        │                         │
        ├─────────────────────────┤
        │ Camera Name        🔇   │  ← info bar (QHBoxLayout)
        └─────────────────────────┘

    The camera name and audio indicator are placed BELOW the video surface
    (not as overlays) to avoid being covered by VLC's rendering.

    Audio is muted by default. Call set_audio(True) to enable it.
    Clicking the widget triggers the audio_callback so the parent can
    enforce single-camera audio selection.

    Attributes:
        camera_name: Display name for this camera.
        url: Full RTSP URL (with credentials if needed).
    """

    def __init__(
        self,
        vlc_instance: vlc.Instance,
        name: str,
        url: str,
    ):
        """
        Args:
            vlc_instance: Shared VLC Instance (carries the low-latency config).
            name: Human-readable camera name (shown in info bar).
            url: RTSP stream URL.
        """
        super().__init__()
        self.camera_name = name
        self.url = url
        self._playing = False

        # --- Styling ---
        self.setStyleSheet("background: #1a1a1a; border: 1px solid #333;")
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(160, 120)

        # --- Layout: video on top, info bar on bottom ---
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # --- Video surface ---
        # This QWidget is the rendering target for VLC. On macOS, VLC's
        # set_nsobject() needs a real NSView pointer. We force Qt to create
        # a native window handle by setting WA_NativeWindow.
        #
        # WA_DontCreateNativeAncestors prevents Qt from also making parent
        # widgets native (which can cause rendering issues).
        self._video_surface = QWidget(self)
        self._video_surface.setAttribute(Qt.WA_DontCreateNativeAncestors)
        self._video_surface.setAttribute(Qt.WA_NativeWindow)
        self._video_surface.setStyleSheet("background: black;")
        layout.addWidget(self._video_surface, 1)  # stretch=1 → takes most space

        # --- Info bar below the video ---
        info_bar = QWidget(self)
        info_bar.setFixedHeight(24)
        info_bar.setStyleSheet("background: #1a1a1a; border: none;")
        info_layout = QHBoxLayout(info_bar)
        info_layout.setContentsMargins(8, 0, 8, 0)
        info_layout.setSpacing(4)

        self._name_label = QLabel(name)
        self._name_label.setStyleSheet(
            "color: #ccc; font-size: 11px; border: none;"
        )
        info_layout.addWidget(self._name_label)
        info_layout.addStretch()

        layout.addWidget(info_bar)

        # --- VLC player setup ---
        self._player = vlc_instance.media_player_new()
        self._media = vlc_instance.media_new(url)
        self._player.set_media(self._media)
        # We don't just mute; we will completely disable the audio track in start()

        log.debug(
            "CameraWidget created: name=%s url=%s", name, url
        )

    # -- Playback control --------------------------------------------------

    def start(self):
        """Start (or restart) RTSP playback, embedding video in this widget."""
        if self._playing:
            return

        # Ensure the video surface is visible and has been painted at least
        # once, so that winId() returns a valid native handle.
        self._video_surface.show()
        self._video_surface.update()

        # Attach VLC to the native window handle (platform-specific).
        # On macOS: winId() returns an NSView* pointer (integer).
        # On Linux: winId() returns an X11 Window ID.
        # On Windows: winId() returns an HWND.
        handle = int(self._video_surface.winId())
        system = platform.system()
        log.debug(
            "Attaching VLC to %s handle=%d for %s",
            system, handle, self.camera_name
        )

        if system == "Darwin":
            self._player.set_nsobject(handle)
        elif system == "Windows":
            self._player.set_hwnd(handle)
        else:
            self._player.set_xwindow(handle)

        self._player.play()
        self._playing = True
        
        # Disable audio track completely to prevent A/V sync latency overhead,
        # without breaking TCP interleaving in the demuxer.
        QTimer.singleShot(1000, lambda: self._player.audio_set_track(-1))
        
        log.debug("Started stream: %s → %s", self.camera_name, self.url)

    def stop(self):
        """Stop RTSP playback and release the stream."""
        if not self._playing:
            return
        self._player.stop()
        self._playing = False
        log.debug("Stopped stream: %s", self.camera_name)


# ===========================================================================
# MainWindow — Grid layout manager and main application window
# ===========================================================================
class MainWindow(QMainWindow):
    """
    Main application window that arranges CameraWidgets in a grid.

    ALL configured cameras are always visible. The grid buttons (1-6) control
    the grid arrangement (rows × columns), not which cameras are shown:
        1 → 1×1     (all cameras stacked in single column)
        2 → 1×2     (two columns)
        3 → 2×2     (four-slot grid)
        4 → 2×2     (same)
        5 → 2×3     (six-slot grid)
        6 → 2×3     (same)

    A bottom control bar has buttons [1]–[6] for arrangement and [Quit].

    Attributes:
        cameras: List of CameraWidget instances (up to 6).
    """

    def __init__(self, cameras_config: list[dict]):
        """
        Args:
            cameras_config: List of camera dicts from cameras.json.
                Each dict must have "name" and "url" keys.
                Optional: "username" and "password" for separate credentials.
        """
        super().__init__()
        self.setWindowTitle("LocalVideo — RTSP Camera Viewer")
        self.resize(1280, 720)
        self.setMinimumSize(640, 480)
        self.setStyleSheet("background: #111;")

        # --- Central widget and main layout ---
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setContentsMargins(4, 4, 4, 4)
        main_layout.setSpacing(4)

        # --- Camera grid ---
        self._grid_widget = QWidget()
        self._grid = QGridLayout(self._grid_widget)
        self._grid.setContentsMargins(0, 0, 0, 0)
        self._grid.setSpacing(2)
        main_layout.addWidget(self._grid_widget, 1)  # stretch=1 → takes all space

        # --- Bottom control bar ---
        controls = QHBoxLayout()
        controls.setSpacing(4)

        # Layout buttons 1–6 (control grid arrangement, not visibility)
        for i in range(1, 7):
            btn = QPushButton(str(i))
            btn.setFixedSize(32, 26)
            btn.setStyleSheet(
                "QPushButton { background: #333; color: white; "
                "border: 1px solid #555; border-radius: 3px; font-size: 12px; }"
                "QPushButton:hover { background: #555; }"
                "QPushButton:pressed { background: #666; }"
            )
            btn.clicked.connect(lambda _, n=i: self.set_grid(n))
            controls.addWidget(btn)

        controls.addStretch()

        # Quit button
        quit_btn = QPushButton("Quit")
        quit_btn.setFixedSize(50, 26)
        quit_btn.setStyleSheet(
            "QPushButton { background: #8b0000; color: white; "
            "border: none; border-radius: 3px; font-size: 12px; }"
            "QPushButton:hover { background: #a00; }"
        )
        quit_btn.clicked.connect(self.close)
        controls.addWidget(quit_btn)

        main_layout.addLayout(controls)

        # --- Create shared VLC instance ---
        # One instance is shared across all cameras for efficiency.
        # The low-latency flags are set here and inherited by all players.
        self._vlc_instance = vlc.Instance(VLC_ARGS)

        # --- Create camera widgets ---
        self.cameras: list[CameraWidget] = []
        for cfg in cameras_config[:6]:  # Max 6 cameras
            url = self._build_url(cfg)
            cam = CameraWidget(
                self._vlc_instance,
                cfg["name"],
                url,
            )
            self.cameras.append(cam)

        log.debug("Created %d camera widgets", len(self.cameras))

        # --- Initial layout: show all cameras ---
        self._current_cols = 0
        self.set_grid(len(self.cameras))

        # --- Delayed start ---
        # Wait for the window to be fully mapped before starting VLC players.
        # This ensures winId() returns valid native handles.
        QTimer.singleShot(500, self._start_all_cameras)

    # -- URL construction ---------------------------------------------------

    @staticmethod
    def _build_url(cfg: dict) -> str:
        """
        Build the full RTSP URL from a camera config dict.

        Supports two formats:
            1. Credentials in URL: {"url": "rtsp://user:pass@host/path"}
            2. Separate fields: {"url": "rtsp://host/path", "username": "u", "password": "p"}

        Args:
            cfg: Camera config dict from cameras.json.

        Returns:
            Full RTSP URL with embedded credentials.
        """
        url = cfg["url"]
        if "username" in cfg and "password" in cfg:
            url = url.replace(
                "rtsp://",
                f"rtsp://{cfg['username']}:{cfg['password']}@",
                1,
            )
        return url

    # -- Grid layout --------------------------------------------------------

    def set_grid(self, cols: int):
        """
        Rearrange ALL cameras into a grid with the given number of columns.

        All cameras remain visible and playing — this only changes the
        grid arrangement. The number of rows is calculated automatically.

        Grid arrangements:
            cols=1 → all cameras in a single column
            cols=2 → 2 columns (2×N grid)
            cols=3 → 3 columns (3×N grid)

        Args:
            cols: Number of columns for the grid (1–3).
        """
        n = len(self.cameras)
        if n == 0:
            return

        # Clamp columns: at least 1, at most 3, at most camera count
        cols = max(1, min(cols, 3, n))

        # Clear the grid layout (detach widgets without destroying them)
        while self._grid.count():
            self._grid.takeAt(0)

        # Reset row/column stretches from previous layout
        for r in range(self._grid.rowCount()):
            self._grid.setRowStretch(r, 0)
        for c in range(self._grid.columnCount()):
            self._grid.setColumnStretch(c, 0)

        # Calculate rows needed
        rows = (n + cols - 1) // cols

        # Place ALL cameras in the grid
        for i, cam in enumerate(self.cameras):
            r, c = divmod(i, cols)
            self._grid.addWidget(cam, r, c)
            cam.show()

        # Equal stretch for all rows and columns
        for r in range(rows):
            self._grid.setRowStretch(r, 1)
        for c in range(cols):
            self._grid.setColumnStretch(c, 1)

        self._current_cols = cols
        log.debug("Grid set to %d columns (%d×%d) for %d cameras", cols, rows, cols, n)

    # -- Camera lifecycle ---------------------------------------------------

    def _start_all_cameras(self):
        """Start playback on all cameras."""
        for cam in self.cameras:
            cam.start()

    # -- Qt event overrides -------------------------------------------------

    def keyPressEvent(self, event):
        """
        Handle keyboard shortcuts:
            1-6:    Switch grid arrangement (columns)
            F:      Toggle fullscreen
            Q/Esc:  Quit application
        """
        key = event.key()
        if key in (Qt.Key_Q, Qt.Key_Escape):
            self.close()
        elif key == Qt.Key_F:
            self.setWindowState(self.windowState() ^ Qt.WindowFullScreen)
        elif Qt.Key_1 <= key <= Qt.Key_6:
            self.set_grid(key - Qt.Key_0)

    def closeEvent(self, event):
        """Stop all camera streams before closing."""
        log.debug("Shutting down — stopping all cameras")
        for cam in self.cameras:
            cam.stop()
        event.accept()


# ===========================================================================
# Entry point
# ===========================================================================
def main():
    """Load camera config and launch the viewer."""

    # --- Load configuration ---
    config_path = Path(__file__).parent / "cameras.json"
    if not config_path.exists():
        print(f"Error: Configuration file not found: {config_path}")
        print("Create cameras.json with your camera definitions. See README.md.")
        sys.exit(1)

    try:
        cameras = json.loads(config_path.read_text())["cameras"]
    except (json.JSONDecodeError, KeyError) as e:
        print(f"Error: Invalid cameras.json: {e}")
        sys.exit(1)

    if not cameras:
        print("Error: No cameras defined in cameras.json")
        sys.exit(1)

    if len(cameras) > 6:
        print(f"Warning: Only the first 6 cameras will be used ({len(cameras)} defined)")

    # --- Launch application ---
    app = QApplication(sys.argv)
    window = MainWindow(cameras)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
