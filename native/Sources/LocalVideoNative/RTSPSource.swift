import Foundation
import CoreMedia
import CRTSPDemux

/// Pulls an RTSP(S) stream's compressed H.264 using an **in-process** libavformat
/// demuxer (`CRTSPDemux`), parses the elementary stream, and emits CMSampleBuffers.
/// Decode + render happen natively downstream (AVSampleBufferDisplayLayer).
///
/// This replaced an `ffmpeg` subprocess. The win: the camera URL (which can embed a
/// password) now lives only in this process's memory and never appears in any process
/// argv, so it can't leak via `ps`/pgrep/Activity Monitor. The demuxed bytes are the
/// same Annex-B H.264 the old `ffmpeg -f h264 -` pipe produced, so the parser and the
/// zero-copy render path are unchanged — and demux is not the latency-critical step.
final class RTSPSource {

    /// Called (on the demux thread) for every decodable video frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called when the stream's status changes.
    var onStatus: ((StreamStatus) -> Void)?

    private let url: String
    private let parser = H264Parser()

    // Demuxer handle + its background thread. All access to `demux` is on the main
    // thread (start/stop/handleRunEnded) so the pointer is never used-after-free.
    private var demux: OpaquePointer?
    private var thread: Thread?
    private var stopping = false
    private var reportedStreaming = false

    init(url: String) {
        self.url = url
        parser.onSampleBuffer = { [weak self] sb in
            guard let self else { return }
            if !self.reportedStreaming {
                self.reportedStreaming = true
                self.onStatus?(.streaming)
            }
            self.onSampleBuffer?(sb)
        }
    }

    func start() {
        stopping = false
        reportedStreaming = false
        onStatus?(.connecting)

        guard let d = url.withCString({ rtsp_demux_create($0) }) else {
            onStatus?(.failed)
            return
        }
        demux = d

        // Keep `self` alive for the lifetime of the thread; balanced in handleRunEnded.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        let t = Thread {
            // C callback: no captures allowed. Routes bytes to the owning source's parser.
            let cb: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int32) -> Void = { userdata, bytes, len in
                guard let userdata, let bytes, len > 0 else { return }
                let src = Unmanaged<RTSPSource>.fromOpaque(userdata).takeUnretainedValue()
                src.parser.append(Data(bytes: bytes, count: Int(len)))
            }
            _ = rtsp_demux_run(d, cb, ctx)
            // Hand the demuxer pointer back to the main thread for teardown so the
            // pointer lifecycle stays single-threaded.
            DispatchQueue.main.async {
                let src = Unmanaged<RTSPSource>.fromOpaque(ctx).takeRetainedValue()
                src.handleRunEnded(d)
            }
        }
        t.name = "rtsp-demux"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    /// The run loop returned (error/EOF, or because stop() was requested). Runs on
    /// the main thread; the only place a demuxer is freed.
    private func handleRunEnded(_ d: OpaquePointer) {
        if demux == d {
            // Ended on its own (not via stop) — surface failure so the app reconnects.
            demux = nil
            rtsp_demux_free(d)
            if !stopping { onStatus?(.failed) }
        } else {
            // stop() already detached this demuxer; free the retired one here.
            rtsp_demux_free(d)
        }
    }

    func stop() {
        stopping = true
        if let d = demux {
            rtsp_demux_stop(d)   // interrupts a blocked connect/read; thread frees it
            demux = nil
        }
        thread = nil
    }
}
