import AVFoundation
import CoreMedia

/// Records one camera's already-compressed H.264 to disk as keyframe-aligned MP4
/// segments — a stream COPY via AVAssetWriter passthrough (no decode/encode). All
/// work happens on a per-camera serial `queue`, off the demux and main threads, so
/// slow disk I/O can never perturb live display. Best-effort: any failure is logged
/// and dropped, never propagated to the live path. See docs/RECORDING_SPEC.md §5,§10,§11.
final class CameraRecorder {

    /// Serial queue all methods must run on (and where appends are dispatched).
    let queue: DispatchQueue

    private let cameraName: String
    private let store: RecordingStore
    private let segmentSeconds: Double

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentStartPTS: CMTime = .invalid
    private var currentPartial: URL?
    private var currentFinal: URL?
    private var currentFormat: CMFormatDescription?
    private var active = true

    /// The final `.mp4` path of the segment currently being written (so the pruner
    /// never deletes it). Read via `queue`.
    private(set) var activeFinalPath: String?

    init(cameraName: String, store: RecordingStore) {
        self.cameraName = cameraName
        self.store = store
        self.segmentSeconds = Double(max(1, store.settings.segmentSeconds))
        self.queue = DispatchQueue(label: "localvideo.recorder.\(RecordingStore.sanitize(cameraName))")
    }

    // MARK: - Ingest (call on `queue`)

    func append(_ sb: CMSampleBuffer) {
        guard active, let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        let isKey = Self.isKeyframe(sb)

        // Not started yet → wait for a keyframe to open the first segment.
        if writer == nil {
            if isKey { startSegment(firstSample: sb, format: fmt, pts: pts) }
            return
        }

        // On a keyframe, rotate if past the target length or the format changed
        // (AVAssetWriter can't change format mid-file).
        if isKey {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, segmentStartPTS))
            let formatChanged = currentFormat.map { !CMFormatDescriptionEqual($0, otherFormatDescription: fmt) } ?? true
            if elapsed >= segmentSeconds || formatChanged {
                finalize(writer: writer, input: input, partial: currentPartial, final: currentFinal)
                startSegment(firstSample: sb, format: fmt, pts: pts)
                return
            }
        }
        appendSample(sb)
    }

    // MARK: - Segment lifecycle

    private func startSegment(firstSample sb: CMSampleBuffer, format fmt: CMFormatDescription, pts: CMTime) {
        guard let paths = store.segmentPaths(cameraName: cameraName, start: Date()) else { return }
        // A stale .partial (prior crash) at this exact path would block the writer.
        try? FileManager.default.removeItem(at: paths.partial)
        do {
            let w = try AVAssetWriter(outputURL: paths.partial, fileType: .mp4)
            w.movieFragmentInterval = CMTime(value: 2, timescale: 1)   // fragment every ~2s → crash-resilient
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            inp.expectsMediaDataInRealTime = true
            guard w.canAdd(inp) else {
                NSLog("CameraRecorder[\(cameraName)]: cannot add input"); return
            }
            w.add(inp)
            guard w.startWriting() else {
                NSLog("CameraRecorder[\(cameraName)]: startWriting failed: \(w.error?.localizedDescription ?? "?")"); return
            }
            w.startSession(atSourceTime: pts)
            writer = w; input = inp
            currentPartial = paths.partial; currentFinal = paths.final
            currentFormat = fmt; segmentStartPTS = pts
            activeFinalPath = paths.final.path
            appendSample(sb)
        } catch {
            NSLog("CameraRecorder[\(cameraName)]: start error: \(error.localizedDescription)")
        }
    }

    private func appendSample(_ sb: CMSampleBuffer) {
        guard let inp = input, inp.isReadyForMoreMediaData else { return }  // best-effort: drop if backpressured
        if !inp.append(sb) {
            NSLog("CameraRecorder[\(cameraName)]: append failed: \(writer?.error?.localizedDescription ?? "?")")
        }
    }

    /// Finalise a segment asynchronously: mark finished, flush, and rename
    /// `.partial → .mp4` on success (or delete a failed partial). Clears the "active"
    /// fields immediately so a new segment can open right away.
    private func finalize(writer: AVAssetWriter?, input: AVAssetWriterInput?, partial: URL?, final: URL?) {
        self.writer = nil; self.input = nil
        self.currentPartial = nil; self.currentFinal = nil
        self.currentFormat = nil; self.segmentStartPTS = .invalid
        self.activeFinalPath = nil
        guard let w = writer, let inp = input, let partial, let final else { return }
        inp.markAsFinished()
        w.finishWriting {
            if w.status == .completed {
                try? FileManager.default.removeItem(at: final)   // paranoia: no stale target
                try? FileManager.default.moveItem(at: partial, to: final)
            } else {
                NSLog("CameraRecorder: finishWriting status \(w.status.rawValue): \(w.error?.localizedDescription ?? "?")")
                try? FileManager.default.removeItem(at: partial)
            }
        }
    }

    /// Stop recording and finalise the last segment. `completion` runs once the file
    /// is flushed (or immediately if nothing was open). Safe to call from any thread.
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.active = false
            guard let w = self.writer, let inp = self.input,
                  let partial = self.currentPartial, let final = self.currentFinal else {
                self.writer = nil; self.input = nil; self.activeFinalPath = nil
                completion?(); return
            }
            self.writer = nil; self.input = nil
            self.currentPartial = nil; self.currentFinal = nil
            self.activeFinalPath = nil
            inp.markAsFinished()
            w.finishWriting {
                if w.status == .completed {
                    try? FileManager.default.removeItem(at: final)
                    try? FileManager.default.moveItem(at: partial, to: final)
                } else {
                    try? FileManager.default.removeItem(at: partial)
                }
                completion?()
            }
        }
    }

    // MARK: - Keyframe detection

    /// A sample is a keyframe unless it's explicitly marked NotSync (set by the parser
    /// on non-IDR slices).
    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(arr) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        if let val = CFDictionaryGetValue(dict, key) {
            return !CFBooleanGetValue(unsafeBitCast(val, to: CFBoolean.self))
        }
        return true
    }
}
