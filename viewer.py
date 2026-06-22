#!/usr/bin/env python3
"""
LocalVideo — Lightweight RTSP Multi-Camera Viewer (OpenCV/FFmpeg Engine)

A minimal, low-latency RTSP camera viewer for local networks.
Uses OpenCV (FFmpeg backend) for frame capture and PySide6 for the UI.

Architecture:
    - Each camera runs a background thread that continuously grabs frames
      from an OpenCV VideoCapture (cv2.CAP_FFMPEG) with TCP + low-delay tuning.
    - The thread keeps ONLY the latest frame, dropping stale ones. This prevents
      frame queuing and TCP stall accumulation — the core of the latency fix.
    - The GUI thread repaints each CameraWidget from the latest frame via a QTimer
      (~30 fps), converting BGR frames to RGB QImage → QPixmap.
    - No audio (acceptable — OpenCV has no audio support, and audio is already
      disabled by design to kill A/V sync latency).

Frame Grabbing Thread (per camera):
    1. Create cv2.VideoCapture with OPENCV_FFMPEG_CAPTURE_OPTIONS set.
    2. Loop: read frame, store in shared variable (atomic overwrite), no queue.
    3. On error or thread stop: release capture and exit.

GUI Repaint (~30 fps QTimer):
    1. Grab latest frame from shared variable.
    2. Convert BGR → RGB, scale to widget size, convert to QImage.
    3. Update QLabel pixmap.

Shutdown:
    1. Flag all threads to stop.
    2. Wait for threads to finish (they release captures).
    3. Close window.

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
import os
import sys
import threading
from pathlib import Path
from threading import Thread, Lock

import cv2
import numpy as np
from PySide6.QtCore import Qt, QTimer, QSize
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

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
# OpenCV/FFmpeg configuration — set BEFORE importing cv2
# ---------------------------------------------------------------------------
# These options are tuned for ultra-low-latency RTSP playback on a local network.
#
# --- Transport ---
# rtsp_transport;tcp        Use TCP instead of UDP. Required for cameras that
#                           block UDP (e.g., camera 2 in this setup).
#
# --- Frame buffering ---
# fflags;nobuffer           Disable internal FFmpeg frame buffering.
#                           This is THE critical knob for latency.
# flags;low_delay           Set FFmpeg's low-delay flag. Disables B-frames
#                           and other reorder buffers in the decoder.
# reorder_queue_size;0      Disable the RTP packet reorder queue in the RTSP
#                           demuxer. Default holds a backlog of packets to fix
#                           out-of-order delivery — on a LAN that backlog is the
#                           single biggest source of steady-state latency (~1s).
# max_delay;0               Don't hold packets waiting to interleave/reorder.
#
# The combination means: no frame queue, read the newest available frame,
# drop stale ones. This is what defeats both the TCP-stall lag accumulation
# AND the steady-state demuxer latency.
os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = (
    "rtsp_transport;tcp"
    "|fflags;nobuffer"
    "|flags;low_delay"
    "|reorder_queue_size;0"
    "|max_delay;0"
)


# ===========================================================================
# FrameBuffer — Thread-safe latest-frame storage
# ===========================================================================
class FrameBuffer:
    """
    Holds the latest frame captured from an RTSP stream.
    Designed for lock-free "latest always wins" semantics:
    the consumer always reads the newest frame, never queues stale ones.

    Attributes:
        _frame: Current frame (numpy array, BGR). None if not yet available.
        _lock: Lock to protect the frame from concurrent read/write.
    """

    def __init__(self):
        """Initialize an empty frame buffer."""
        self._frame = None
        self._lock = Lock()

    def put(self, frame: np.ndarray):
        """
        Store a new frame, overwriting the previous one.

        Args:
            frame: NumPy array (BGR, HxWx3 uint8).
        """
        with self._lock:
            self._frame = frame

    def get(self):
        """
        Retrieve the latest frame (or None if empty).

        Returns:
            NumPy array (BGR) or None.
        """
        with self._lock:
            return self._frame.copy() if self._frame is not None else None


# ===========================================================================
# CameraFrameGrabber — Background thread for a single camera
# ===========================================================================
class CameraFrameGrabber(Thread):
    """
    Daemon thread that continuously grabs frames from an RTSP stream
    via OpenCV VideoCapture (cv2.CAP_FFMPEG).

    On error, logs the error and stops. The thread is a daemon, so it
    will be forcibly terminated when the main thread exits (no cleanup needed).

    Attributes:
        camera_name: Display name for logging.
        url: RTSP URL (with credentials).
        frame_buffer: FrameBuffer instance to store the latest frame.
        _stop_event: Threading event to signal the thread to stop.
    """

    def __init__(self, camera_name: str, url: str, frame_buffer: FrameBuffer):
        """
        Args:
            camera_name: Display name for this camera.
            url: RTSP stream URL.
            frame_buffer: FrameBuffer to store frames into.
        """
        super().__init__(daemon=True)
        self.camera_name = camera_name
        self.url = url
        self.frame_buffer = frame_buffer
        self._stop_event = threading.Event()

    def stop(self):
        """Signal the thread to stop (graceful shutdown)."""
        self._stop_event.set()

    def run(self):
        """
        Main thread loop: open the RTSP stream and grab frames continuously.
        Stores only the latest frame in frame_buffer. On error, logs and exits.
        """
        log.debug(
            "CameraFrameGrabber started for %s", self.camera_name
        )

        # Prefer hardware decode (VideoToolbox on Apple Silicon). HW decode is
        # both faster and lower-latency than software H.264 decode — it's what
        # native low-latency viewers use. Fall back to software if the OpenCV
        # build lacks the HW-acceleration constructor or the open fails.
        cap = None
        accel = getattr(cv2, "VIDEO_ACCELERATION_ANY", None)
        if accel is not None:
            try:
                cap = cv2.VideoCapture(
                    self.url, cv2.CAP_FFMPEG,
                    [cv2.CAP_PROP_HW_ACCELERATION, accel],
                )
                if not cap.isOpened():
                    cap.release()
                    cap = None
                else:
                    log.debug("HW-accelerated decode enabled for %s", self.camera_name)
            except Exception:
                cap = None
        if cap is None:
            cap = cv2.VideoCapture(self.url, cv2.CAP_FFMPEG)
        if not cap.isOpened():
            log.error(
                "Failed to open RTSP stream: %s", self.camera_name
            )
            return

        # Cap OpenCV's own decoded-frame buffer to a single frame so reads
        # always return the freshest frame (the FFmpeg backend honors this on
        # most builds; harmless if ignored).
        try:
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        except Exception:
            pass

        frame_count = 0
        try:
            while not self._stop_event.is_set():
                ret, frame = cap.read()
                if not ret:
                    log.warning(
                        "Frame read failed for %s; stream may have ended",
                        self.camera_name,
                    )
                    break

                # Store only the latest frame (overwrite previous).
                # The GUI thread will read this via frame_buffer.get().
                self.frame_buffer.put(frame)
                frame_count += 1

                # Log progress every 60 frames (~2 sec at 30 fps)
                if frame_count % 60 == 0:
                    log.debug(
                        "CameraFrameGrabber %s: %d frames captured",
                        self.camera_name, frame_count,
                    )
        except Exception as e:
            log.error(
                "CameraFrameGrabber %s exception: %s", self.camera_name, e
            )
        finally:
            cap.release()
            log.debug(
                "CameraFrameGrabber stopped for %s (%d frames)",
                self.camera_name, frame_count,
            )


# ===========================================================================
# CameraWidget — A single camera view with latest-frame rendering
# ===========================================================================
class CameraWidget(QWidget):
    """
    Displays a single RTSP stream rendered from the latest frame.

    Layout:
        ┌─────────────────────────┐
        │                         │
        │   Latest frame here     │  ← _video_label (QLabel with QPixmap)
        │   (updated ~30 fps)     │
        │                         │
        ├─────────────────────────┤
        │ Camera Name             │  ← info bar
        └─────────────────────────┘

    The frame is grabbed by a background CameraFrameGrabber thread.
    The GUI updates the display via a QTimer (refresh_interval).

    Attributes:
        camera_name: Display name for this camera.
        url: Full RTSP URL (with credentials if needed).
        _frame_buffer: FrameBuffer holding the latest frame.
        _grabber_thread: CameraFrameGrabber thread (daemon).
        _refresh_timer: QTimer that repaints the frame (~30 fps).
    """

    def __init__(self, name: str, url: str, refresh_interval: int = 33):
        """
        Args:
            name: Human-readable camera name (shown in info bar).
            url: RTSP stream URL.
            refresh_interval: GUI refresh rate in milliseconds (default 33ms ≈ 30 fps).
        """
        super().__init__()
        self.camera_name = name
        self.url = url
        self._refresh_interval = refresh_interval

        # --- Styling ---
        self.setStyleSheet("background: #1a1a1a; border: 1px solid #333;")
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(160, 120)

        # --- Layout: video on top, info bar on bottom ---
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # --- Video display (QLabel for pixmap rendering) ---
        self._video_label = QLabel()
        self._video_label.setStyleSheet("background: black;")
        self._video_label.setAlignment(Qt.AlignCenter)
        self._video_label.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        layout.addWidget(self._video_label, 1)

        # --- Info bar below the video ---
        info_bar = QWidget()
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

        # --- Frame buffer and grabber thread ---
        self._frame_buffer = FrameBuffer()
        self._grabber_thread = CameraFrameGrabber(name, url, self._frame_buffer)
        self._grabber_thread.start()

        # --- GUI refresh timer ---
        self._refresh_timer = QTimer()
        self._refresh_timer.timeout.connect(self._repaint_frame)
        self._refresh_timer.start(self._refresh_interval)

        log.debug(
            "CameraWidget created: name=%s url=%s", name, url
        )

    def _repaint_frame(self):
        """
        Called by the refresh timer (~30 fps): grab the latest frame from
        the frame buffer, convert BGR → RGB, scale to widget size, and
        update the QLabel pixmap. All work is off the network thread.
        """
        frame = self._frame_buffer.get()
        if frame is None:
            return

        # Scale to fit WITHIN the widget while preserving the source aspect
        # ratio. The QLabel is center-aligned on a black background, so the
        # leftover space becomes clean letterbox/pillarbox bars (no stretching).
        lw, lh = self._video_label.width(), self._video_label.height()
        fh, fw = frame.shape[:2]
        if lw > 0 and lh > 0 and fw > 0 and fh > 0:
            scale = min(lw / fw, lh / fh)
            new_w = max(1, int(fw * scale))
            new_h = max(1, int(fh * scale))
            frame = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LINEAR)

        # Convert BGR (OpenCV) → RGB (Qt)
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        # Convert NumPy array → QImage (8-bit RGB)
        # Note: np.ascontiguousarray ensures the array is C-contiguous for Qt.
        h, w, ch = frame_rgb.shape
        bytes_per_line = ch * w
        q_image = QImage(
            np.ascontiguousarray(frame_rgb).data,
            w, h,
            bytes_per_line,
            QImage.Format_RGB888
        )

        # Update the label
        pixmap = QPixmap.fromImage(q_image)
        self._video_label.setPixmap(pixmap)

    def closeEvent(self, event):
        """Stop the refresh timer and signal the grabber thread to stop."""
        self._refresh_timer.stop()
        self._grabber_thread.stop()
        event.accept()


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

        # --- Create camera widgets ---
        self.cameras: list[CameraWidget] = []
        for cfg in cameras_config[:6]:  # Max 6 cameras
            url = self._build_url(cfg)
            cam = CameraWidget(
                cfg["name"],
                url,
            )
            self.cameras.append(cam)

        log.debug("Created %d camera widgets", len(self.cameras))

        # --- Initial layout: show all cameras ---
        self._current_cols = 0
        self.set_grid(len(self.cameras))

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
        """Stop all camera streams and threads before closing."""
        log.debug("Shutting down — stopping all cameras")
        for cam in self.cameras:
            cam.closeEvent(event)
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
