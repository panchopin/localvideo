import AppKit
import AVFoundation

/// An NSView backed by an AVSampleBufferDisplayLayer.
///
/// AVSampleBufferDisplayLayer is the zero-copy, low-latency render path on
/// Apple platforms: we hand it H.264 CMSampleBuffers, it decodes them on
/// VideoToolbox (hardware) and renders the result straight on the GPU — no
/// frame ever gets copied into our process's address space. Tagging each
/// sample buffer "DisplayImmediately" makes it present ASAP with no internal
/// queueing clock, which is what keeps latency down.
final class VideoLayerView: NSView {

    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: - Zoom-in-place state
    //
    // Digital zoom is a pure geometry change on `displayLayer` (scale + offset). The
    // decode/enqueue path is untouched, so it adds ZERO latency — frames keep arriving
    // and presenting DisplayImmediately; we only re-frame the layer between them. Every
    // geometry write is wrapped in a CATransaction with actions disabled so the picture
    // snaps instantly and never animates a step behind the live stream.

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 6

    /// Current zoom factor (1 = normal/fit, up to `maxZoom`).
    private(set) var zoomScale: CGFloat = 1
    /// Normalized content point [0,1]² shown at the view's center. (0.5,0.5) = centered.
    /// Layer coords are bottom-left origin, so y=0 is the bottom of the frame.
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)

    /// True once zoomed past 1× (with a small epsilon).
    var isZoomed: Bool { zoomScale > minZoom + 0.001 }
    /// Fired after any zoom change so the owner can refresh its indicator.
    var onZoomChanged: (() -> Void)?

    /// Rectangular clip applied to the container *only while zoomed*.
    ///
    /// An `AVSampleBufferDisplayLayer` is composited on the GPU in a way that
    /// ignores an ancestor's `masksToBounds`, so the oversized (zoomed) layer
    /// spills over neighboring tiles. An explicit `mask` DOES clip it — but a
    /// mask forces offscreen compositing, so we install it only when zoomed and
    /// remove it at 1×, keeping the normal low-latency render path untouched.
    private let clipMask: CALayer = {
        let m = CALayer()
        m.backgroundColor = NSColor.black.cgColor   // opaque → alpha 1 → shows through
        return m
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true   // clips ordinary sublayers (not the video layer — see clipMask)
        layer = root

        displayLayer.videoGravity = .resizeAspect   // preserve aspect ratio (letterbox)
        displayLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        applyGeometry()   // re-frames the layer for the current size + zoom (identity at 1×)
    }

    // MARK: - Zoom / pan API (driven by CameraTileView gestures)

    /// Multiply the zoom by `scaleDelta`, keeping the content point under `p` (in this
    /// view's coordinates) fixed — the standard focus-preserving zoom about the pointer.
    func applyZoom(scaleDelta: CGFloat, aroundPointInView p: CGPoint) {
        let b = bounds
        guard b.width > 0, b.height > 0, scaleDelta > 0 else { return }

        let newScale = min(maxZoom, max(minZoom, zoomScale * scaleDelta))
        if abs(newScale - zoomScale) < 0.0001 { return }

        // Content point (normalized to the scaled layer) currently under the pointer.
        let oldOrigin = layerOrigin(scale: zoomScale, center: zoomCenter, in: b)
        let oldW = b.width * zoomScale, oldH = b.height * zoomScale
        let normX = (p.x - oldOrigin.x) / oldW
        let normY = (p.y - oldOrigin.y) / oldH

        // Solve for the center that keeps that content point under the pointer.
        let newW = b.width * newScale, newH = b.height * newScale
        let newOriginX = p.x - normX * newW
        let newOriginY = p.y - normY * newH

        zoomScale = newScale
        if newScale <= minZoom + 0.001 {
            zoomScale = minZoom
            zoomCenter = CGPoint(x: 0.5, y: 0.5)
        } else {
            zoomCenter = CGPoint(x: (b.midX - newOriginX) / newW,
                                 y: (b.midY - newOriginY) / newH)
        }
        applyGeometry()      // clamps + writes the frame, and re-derives zoomCenter
        onZoomChanged?()
    }

    /// Shift the visible crop by (dx, dy) content-space points (from a drag or scroll pan).
    /// No-op at 1×. Clamping in `applyGeometry` keeps the crop inside the content.
    func panBy(dxInView dx: CGFloat, dyInView dy: CGFloat) {
        guard isZoomed else { return }
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let origin = layerOrigin(scale: zoomScale, center: zoomCenter, in: b)
        let w = b.width * zoomScale, h = b.height * zoomScale
        zoomCenter = CGPoint(x: (b.midX - (origin.x + dx)) / w,
                             y: (b.midY - (origin.y + dy)) / h)
        applyGeometry()
    }

    /// Return to 1× / centered. No-op if already at 1×.
    func resetZoom() {
        guard isZoomed else { return }
        zoomScale = minZoom
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
        applyGeometry()
        onZoomChanged?()
    }

    // MARK: - Geometry

    /// Clamped layer origin for a given scale/center so the scaled frame always fully
    /// covers the tile (never reveals gutters beyond the normal letterbox).
    private func layerOrigin(scale: CGFloat, center: CGPoint, in b: CGRect) -> CGPoint {
        let w = b.width * scale, h = b.height * scale
        let ox = min(0, max(b.width - w, b.midX - center.x * w))
        let oy = min(0, max(b.height - h, b.midY - center.y * h))
        return CGPoint(x: ox, y: oy)
    }

    /// Write the (clamped) zoomed frame to `displayLayer` with no implicit animation,
    /// and fold the clamp back into `zoomCenter` so state matches what's on screen.
    private func applyGeometry() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let w = b.width * zoomScale, h = b.height * zoomScale
        let origin = layerOrigin(scale: zoomScale, center: zoomCenter, in: b)
        zoomCenter = CGPoint(x: (b.midX - origin.x) / w, y: (b.midY - origin.y) / h)

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // hard snap — never lag the live stream
        displayLayer.frame = CGRect(x: origin.x, y: origin.y, width: w, height: h)

        // Clip the oversized video layer to the tile ONLY while zoomed. The mask
        // reliably clips the AVSampleBufferDisplayLayer (ancestor masksToBounds does
        // not); removing it at 1× keeps the resting render path offscreen-free.
        if isZoomed {
            clipMask.frame = b
            if layer?.mask !== clipMask { layer?.mask = clipMask }
        } else if layer?.mask != nil {
            layer?.mask = nil
        }
        CATransaction.commit()
    }

    /// Clear the currently displayed frame (e.g. on reconnect) so a stalled
    /// image doesn't linger while the new connection comes up.
    func flushDisplay() {
        displayLayer.flushAndRemoveImage()
    }

    /// Enqueue a decoded-ready sample buffer for immediate display.
    /// Must be called on the main thread.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
        // If the layer isn't ready, we simply drop the frame — for a live feed
        // staying current matters more than showing every frame.
    }
}
