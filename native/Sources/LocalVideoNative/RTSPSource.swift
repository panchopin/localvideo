import Foundation
import CoreMedia

/// Pulls an RTSP stream's compressed H.264 via an `ffmpeg` subprocess used as a
/// pure demuxer (`-c:v copy`, no decode), parses the elementary stream, and
/// emits CMSampleBuffers. Decode + render happen natively downstream
/// (AVSampleBufferDisplayLayer), so ffmpeg here only moves tiny compressed data.
final class RTSPSource {

    /// Called (on a background queue) for every decodable video frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called (on a background queue) when the stream's status changes.
    var onStatus: ((StreamStatus) -> Void)?

    private let url: String
    private let ffmpegPath: String
    private let parser = H264Parser()
    private var process: Process?
    private var stopping = false
    private var reportedStreaming = false

    /// Resolve ffmpeg across common install locations (a bundled .app won't
    /// inherit a shell PATH that includes Homebrew).
    static let defaultFFmpegPath: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/ffmpeg"
    }()

    init(url: String, ffmpegPath: String = RTSPSource.defaultFFmpegPath) {
        self.url = url
        self.ffmpegPath = ffmpegPath
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-rtsp_transport", "tcp",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-avioflags", "direct",
            "-i", url,
            "-an",                 // no audio
            "-c:v", "copy",        // demux only — do NOT decode here
            "-bsf:v", "dump_extra=freq=keyframe",  // ensure SPS/PPS before keyframes
            "-f", "h264",          // raw Annex-B elementary stream
            "-",                   // to stdout
        ]

        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        // Discard stderr: it can contain the URL (credentials) and we don't log it.
        proc.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.parser.append(data)
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self, !self.stopping else { return }
            self.onStatus?(.failed)
        }

        do {
            try proc.run()
            process = proc
        } catch {
            onStatus?(.failed)
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }
}
