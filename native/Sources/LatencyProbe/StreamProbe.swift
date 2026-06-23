import Foundation

/// Tool A — health & regression probe.
///
/// Runs a separate ffmpeg that emits 1 frame/s as PNG (same transport flags as
/// production), OCRs the OSD clock on each, and reports drift (the signal) plus
/// FPS and OCR success. Absolute lag is reported only as a coarse bucket — the
/// probe's own decode path is slower than the app's, so its absolute value is
/// not the app's latency (see docs/STREAM_LATENCY_EVALUATION.md).
final class StreamProbe {
    private struct Sample { let elapsed: Double; let delta: Double }

    private let name: String
    private let url: String
    private let duration: Double
    private let ffmpegPath: String

    private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private var buffer = Data()

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var framesReceived = 0
    private var ocrSucceeded = 0
    private var startTime: Date?

    // OCR runs off the reader thread so slow OCR can't back up the pipe and
    // inflate T_received (which would masquerade as rising lag).
    private let ocrQueue = DispatchQueue(label: "probe.ocr")
    private let ocrGroup = DispatchGroup()

    init(name: String, url: String, duration: Double, ffmpegPath: String) {
        self.name = name
        self.url = url
        self.duration = duration
        self.ffmpegPath = ffmpegPath
    }

    func run() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-rtsp_transport", "tcp", "-fflags", "nobuffer", "-flags", "low_delay",
            "-i", url,
            "-an", "-vf", "fps=1", "-f", "image2pipe", "-c:v", "png", "-",
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice   // never surface URL/credentials

        do { try proc.run() } catch {
            print("  ffmpeg failed to launch"); return
        }
        startTime = Date()

        // Read the pipe on a background thread with a blocking loop — more
        // reliable in a bare CLI than readabilityHandler (which depends on
        // run-loop/GCD scheduling that isn't set up here).
        let reader = Thread { [weak self] in
            let handle = outPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }   // EOF when ffmpeg exits
                self?.consume(chunk)
            }
        }
        reader.start()

        Thread.sleep(forTimeInterval: duration)
        proc.terminate()
        Thread.sleep(forTimeInterval: 0.2)        // let the reader drain the last frame
        _ = ocrGroup.wait(timeout: .now() + 20)   // finish any queued OCR
        report()
    }

    // MARK: - PNG framing (split concatenated PNGs from image2pipe)

    private lazy var signatureData = Data(pngSignature)
    private var pendingFrameStart: Int?
    private var scanFrom = 0

    /// Split concatenated PNGs incrementally and in O(n): advance a scan cursor
    /// with an efficient byte search, emit the bytes between consecutive
    /// signatures as complete frames, and compact the buffer down to the current
    /// (still-incomplete) frame so it never grows unbounded.
    private func consume(_ data: Data) {
        buffer.append(data)
        while scanFrom < buffer.count,
              let range = buffer.range(of: signatureData, in: scanFrom..<buffer.count) {
            if let start = pendingFrameStart {
                enqueueFrame(buffer.subdata(in: start..<range.lowerBound))
            }
            pendingFrameStart = range.lowerBound
            scanFrom = range.upperBound
        }
        if let start = pendingFrameStart, start > 0 {
            buffer.removeSubrange(0..<start)
            scanFrom -= start
            pendingFrameStart = 0
        }
    }

    /// Stamp arrival time immediately (accurate T_received), then OCR off-thread.
    private func enqueueFrame(_ png: Data) {
        let arrival = Date()
        let t0 = startTime ?? arrival
        lock.lock(); framesReceived += 1; lock.unlock()

        ocrGroup.enter()
        ocrQueue.async { [weak self] in
            defer { self?.ocrGroup.leave() }
            guard let self, let reading = OSDReader.read(pngData: png, now: arrival) else { return }
            let sample = Sample(elapsed: arrival.timeIntervalSince(t0),
                                delta: arrival.timeIntervalSince(reading.time))
            self.lock.lock(); self.ocrSucceeded += 1; self.samples.append(sample); self.lock.unlock()
        }
    }

    // MARK: - Report

    private func report() {
        lock.lock()
        let samples = self.samples
        let frames = framesReceived
        let ocr = ocrSucceeded
        lock.unlock()

        let elapsed = max(samples.last?.elapsed ?? duration, 1)
        let fps = Double(frames) / elapsed
        let ocrRate = frames > 0 ? Double(ocr) / Double(frames) : 0

        guard samples.count >= 2 else {
            print("  Verdict: BLOCKED — only \(ocr) OSD reads (frames=\(frames), fps=\(String(format: "%.1f", fps))).")
            print("  Likely: stream offline, no OSD clock, or OCR couldn't read it (check ROI/clock).")
            return
        }

        let deltas = samples.map { $0.delta }
        let meanDelta = deltas.reduce(0, +) / Double(deltas.count)
        let slope = linearSlope(samples)          // seconds of lag gained per second
        let totalDrift = slope * elapsed          // projected drift over the window

        // Heuristic verdicts.
        let fpsOK = fps >= 0.7                     // ~1 fps sampling; <0.7 means stalls
        let driftRising = totalDrift > 1.0         // grew >1s across the window
        let verdict = !fpsOK ? "FAIL (low/stalled FPS)"
                    : driftRising ? "FAIL (lag rising — buffer/TCP-trap)"
                    : "PASS"

        print("  Verdict: \(verdict)")
        print(String(format: "  fps≈%.2f   ocr_ok=%.0f%%   samples=%d", fps, ocrRate * 100, samples.count))
        print(String(format: "  drift=%+.0f ms/s (≈%+.1fs over %.0fs)  %@",
                     slope * 1000, totalDrift, elapsed, driftRising ? "← RISING" : "(flat)"))
        print(String(format: "  coarse lag bucket: ~%.1fs  (probe pipeline, NOT the app's latency)", meanDelta))
    }

    /// Least-squares slope of delta over elapsed time.
    private func linearSlope(_ samples: [Sample]) -> Double {
        let n = Double(samples.count)
        let sx = samples.reduce(0) { $0 + $1.elapsed }
        let sy = samples.reduce(0) { $0 + $1.delta }
        let sxx = samples.reduce(0) { $0 + $1.elapsed * $1.elapsed }
        let sxy = samples.reduce(0) { $0 + $1.elapsed * $1.delta }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-9 else { return 0 }
        return (n * sxy - sx * sy) / denom
    }
}
