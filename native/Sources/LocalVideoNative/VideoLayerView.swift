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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root

        displayLayer.videoGravity = .resizeAspect   // preserve aspect ratio (letterbox)
        displayLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
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
