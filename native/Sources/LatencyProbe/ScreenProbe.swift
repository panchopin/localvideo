import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Tool B — app latency via the rendered window.
///
/// Captures a target window (LocalVideo, or a reference viewer) with
/// ScreenCaptureKit, OCRs the OSD clock, and uses the **flip-edge** method:
/// when the clock's second increments, the camera time just crossed an integer
/// second, so `latency = T_capture − that_second`. Resolution ≈ one capture
/// interval. Run it on each viewer and compare medians for an app-vs-app number
/// (the camera-clock offset cancels in the difference).
@available(macOS 12.3, *)
final class ScreenProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    private let windowQuery: String
    private let duration: Double
    private let fps: Int
    private let outputQueue = DispatchQueue(label: "probe.screen.out")

    private var stream: SCStream?
    private let lock = NSLock()
    private var lastSecond: Date?
    private var flipLatencies: [Double] = []
    private var frames = 0
    private var ocrFrames = 0

    init(windowQuery: String, duration: Double, fps: Int) {
        self.windowQuery = windowQuery
        self.duration = duration
        self.fps = fps
    }

    func run() {
        guard let window = findWindow() else { return }
        let appName = window.owningApplication?.applicationName ?? "?"
        print("  target: \"\(window.title ?? "")\" (\(appName)), \(Int(window.frame.width))×\(Int(window.frame.height))pt")

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)    // ~Retina pixels for legible OSD
        config.height = Int(window.frame.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            print("  addStreamOutput failed: \(error.localizedDescription)"); return
        }
        self.stream = stream

        let startSem = DispatchSemaphore(value: 0)
        var startError: Error?
        stream.startCapture { startError = $0; startSem.signal() }
        startSem.wait()
        if let startError {
            print("  startCapture failed: \(startError.localizedDescription)")
            print("  → Grant Screen Recording permission (System Settings ▸ Privacy & Security ▸ Screen Recording) and retry.")
            return
        }

        Thread.sleep(forTimeInterval: duration)

        let stopSem = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in stopSem.signal() }
        _ = stopSem.wait(timeout: .now() + 5)
        report()
    }

    // MARK: - Window discovery

    private func findWindow() -> SCWindow? {
        let sem = DispatchSemaphore(value: 0)
        var found: SCWindow?
        var captureError: Error?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            captureError = error
            let windows = content?.windows ?? []
            // Prefer an application-name match (avoids matching e.g. a Terminal
            // window whose title merely contains the query string).
            found = windows.first { ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(self.windowQuery) }
                ?? windows.first { ($0.title ?? "").localizedCaseInsensitiveContains(self.windowQuery) }
            sem.signal()
        }
        sem.wait()
        if let captureError {
            print("  Screen capture unavailable: \(captureError.localizedDescription)")
            print("  → Grant Screen Recording permission and retry.")
            return nil
        }
        if found == nil {
            print("  No on-screen window matching \"\(windowQuery)\". Is the app open and visible (not minimized)?")
        }
        return found
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        // Only count "complete" frames (skip idle/blank status frames).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = Date()
        lock.lock(); frames += 1; lock.unlock()

        guard let reading = OSDReader.read(pixelBuffer: pixelBuffer, now: now, level: .fast) else { return }

        lock.lock()
        ocrFrames += 1
        if let last = lastSecond {
            let step = reading.time.timeIntervalSince(last)
            if abs(step - 1.0) < 0.5 {
                // Clean +1s flip we witnessed → the boundary just occurred.
                flipLatencies.append(now.timeIntervalSince(reading.time))
                lastSecond = reading.time
            } else if abs(step) >= 0.5 {
                // Jump/glitch (OCR noise or gap) — resync without counting.
                lastSecond = reading.time
            }
        } else {
            lastSecond = reading.time   // first observation — can't time its flip
        }
        lock.unlock()
    }

    // MARK: - Report

    private func report() {
        lock.lock()
        let latencies = flipLatencies.sorted()
        let frames = self.frames, ocr = ocrFrames
        lock.unlock()

        let capFps = Double(frames) / duration
        guard latencies.count >= 2 else {
            print("  Verdict: BLOCKED — only \(latencies.count) clock flips captured (frames=\(frames), ocr=\(ocr)).")
            print("  Likely: window OSD not legible at this scale, app not visible, or too few seconds elapsed.")
            return
        }
        func pct(_ p: Double) -> Double { latencies[min(latencies.count - 1, Int(p * Double(latencies.count)))] }
        let median = latencies[latencies.count / 2]
        let resolution = 1.0 / Double(fps)

        print(String(format: "  capture≈%.0ffps   flips=%d   ocr_frames=%d", capFps, latencies.count, ocr))
        print(String(format: "  latency (camera→window): median=%.0f ms  min=%.0f ms  p90=%.0f ms",
                     median * 1000, latencies.first! * 1000, pct(0.9) * 1000))
        print(String(format: "  ±%.0f ms capture resolution; plus camera/Mac NTP offset. Compare medians across viewers for app-vs-app.",
                     resolution * 1000))
    }
}
