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

    /// The render layer. `var`, not `let`: a decode session that macOS has torn down
    /// can be unrecoverable, and the only cure is a fresh layer (see `recoverDisplay`).
    private(set) var displayLayer = VideoLayerView.makeDisplayLayer()

    private static func makeDisplayLayer() -> AVSampleBufferDisplayLayer {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect   // preserve aspect ratio (letterbox)
        l.backgroundColor = NSColor.black.cgColor
        return l
    }

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

        root.addSublayer(displayLayer)
        observeDecodeFailures()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Tokens for the block-based observers below (`removeObserver(self)` would NOT
    /// unregister those — the token is the observer, not `self`).
    private var observerTokens: [NSObjectProtocol] = []

    deinit { observerTokens.forEach(NotificationCenter.default.removeObserver) }

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

    // MARK: - Display health, enqueue & decoder recovery
    //
    // The render layer can be knocked out from under a perfectly healthy stream:
    // macOS revokes decoder resources (app occluded/backgrounded, another process
    // claims the decoder, sleep/wake) and sets `requiresFlushToResumeDecoding` with
    // status `.failed`, or a discontinuous/corrupt bitstream trips a decode error.
    //
    // Both need a flush to resume — and per AVSampleBufferDisplayLayer's contract the
    // FIRST buffer after ANY flush must be an IDR (keyframe): a flush discards the
    // decoder's reference frames, so a P-frame fed to it decodes to nothing. Flushing
    // and then feeding the next arbitrary frame therefore leaves the picture frozen
    // until the next keyframe — and if the flush is repeated per frame, forever after.
    // That is the "recording is perfect but the tile shows ~2 fps" bug: display pinned
    // to the camera's KEYFRAME rate, while the recorder (which never decodes) is fine.
    //
    // So: flush at most once per failure, then gate on the next keyframe, and escalate
    // to a brand-new layer if a flush didn't take. Nothing here touches the healthy
    // path — a streaming layer never enters it, and no buffering is added.

    /// Per-interval render counters (see `consumeStats`). Main thread only.
    struct Stats {
        var received = 0            // frames handed to us by the parser
        var enqueued = 0            // frames actually given to the decoder
        var droppedNotReady = 0     // layer's queue was full (back-pressure)
        var droppedAwaitingKey = 0  // post-flush, waiting for an IDR (expected, brief)
        var flushes = 0             // recoveries attempted this interval
        var rebuilds = 0            // layer replacements this interval
    }

    private var stats = Stats()
    /// True after a flush/rebuild: only a keyframe may be enqueued next.
    private var awaitingKeyframe = false
    /// Rate-limiting for the decode-error log (it can fire per frame).
    private var decodeErrorsSinceLog = 0
    private var lastDecodeErrorLogAt = Date.distantPast

    /// Snapshot and reset the counters. Called ~1 Hz by the app's health timer, which
    /// compares `received` against `enqueued` to spot a stalled display.
    func consumeStats() -> Stats {
        let s = stats
        stats = Stats()
        return s
    }

    /// One-line layer state for diagnostics (goes into the stall log).
    func layerDiagnostics() -> String {
        let status: String
        switch displayLayer.status {
        case .unknown: status = "unknown"
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        @unknown default: status = "?"
        }
        let err = displayLayer.error.map { " error=\($0.localizedDescription)" } ?? ""
        return "status=\(status) needsFlush=\(displayLayer.requiresFlushToResumeDecoding) ready=\(displayLayer.isReadyForMoreMediaData)\(err)"
    }

    /// Clear the currently displayed frame (e.g. on reconnect) so a stalled
    /// image doesn't linger while the new connection comes up.
    func flushDisplay() {
        displayLayer.flushAndRemoveImage()
        awaitingKeyframe = true   // post-flush the decoder has no reference frame
    }

    /// Bring a stalled layer back. `hard` replaces the layer outright — the only cure
    /// when the decode session is gone for good and `flush()` won't clear `.failed`.
    /// Either way the next enqueue waits for a keyframe.
    func recoverDisplay(hard: Bool) {
        if hard {
            let old = displayLayer
            let fresh = VideoLayerView.makeDisplayLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fresh.frame = old.frame
            layer?.insertSublayer(fresh, above: old)
            old.removeFromSuperlayer()
            CATransaction.commit()
            displayLayer = fresh
            applyGeometry()
            stats.rebuilds += 1
        } else {
            displayLayer.flush()
            stats.flushes += 1
        }
        awaitingKeyframe = true
    }

    /// Enqueue a decoded-ready sample buffer for immediate display.
    /// Must be called on the main thread.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        stats.received += 1

        // Decoder resources revoked or a decode failure: flush ONCE (the keyframe gate
        // below stops us flushing again on every frame, which would pin the picture to
        // the keyframe rate) and resume from the next IDR.
        if !awaitingKeyframe,
           displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            recoverDisplay(hard: false)
        }

        if awaitingKeyframe {
            guard VideoLayerView.isKeyframe(sampleBuffer) else {
                stats.droppedAwaitingKey += 1
                return
            }
            awaitingKeyframe = false
        }

        guard displayLayer.isReadyForMoreMediaData else {
            // Queue full (decoder behind): drop this frame — for a live feed staying
            // current beats showing every frame. Deliberately NOT gated on a keyframe
            // afterwards: the decoder tolerates a gap (brief artifacts, self-healing at
            // the next IDR), whereas gating here would turn an occasional back-pressure
            // blip into keyframe-rate video. A SUSTAINED gap is caught by the app's
            // display-health check, which drives a real recovery.
            stats.droppedNotReady += 1
            return
        }

        displayLayer.enqueue(sampleBuffer)
        stats.enqueued += 1
    }

    /// A sample is a keyframe unless it carries the `NotSync` attachment (set by
    /// H264Parser for non-IDR slices).
    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(atts) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let raw = CFDictionaryGetValue(dict, key) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(raw, to: CFBoolean.self))
    }

    /// Log why the layer failed — this is the breadcrumb that names the cause the next
    /// time a tile degrades in the field. Recovery itself happens on the next frame.
    private func observeDecodeFailures() {
        let nc = NotificationCenter.default
        observerTokens.append(nc.addObserver(forName: .AVSampleBufferDisplayLayerFailedToDecode,
                       object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as AnyObject?) === self.displayLayer else { return }
            self.decodeErrorsSinceLog += 1
            guard Date().timeIntervalSince(self.lastDecodeErrorLogAt) >= 5 else { return }
            let err = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey as String] as? NSError
            NSLog("VideoLayerView: decode failed x\(self.decodeErrorsSinceLog) — \(err?.localizedDescription ?? "?") (\(self.layerDiagnostics()))")
            self.decodeErrorsSinceLog = 0
            self.lastDecodeErrorLogAt = Date()
        })
        observerTokens.append(nc.addObserver(forName: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
                       object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as AnyObject?) === self.displayLayer else { return }
            NSLog("VideoLayerView: requiresFlushToResumeDecoding changed — \(self.layerDiagnostics())")
        })
    }
}
