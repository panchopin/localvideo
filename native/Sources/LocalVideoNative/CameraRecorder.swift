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
    private let wantsAudio: Bool

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentStartPTS: CMTime = .invalid
    private var currentPartial: URL?
    private var currentFinal: URL?
    private var currentFormat: CMFormatDescription?
    private var active = true

    // Audio (G.711 → PCM, muxed as a second track in a .mov). All queue-confined.
    private var audioConfig: AudioStreamConfig?
    private var audioFormatDesc: CMAudioFormatDescription?
    private var audioInput: AVAssetWriterInput?
    /// Next audio PTS within the current segment (audio-rate timescale), kept
    /// contiguous for smooth playback. `.invalid` until the first packet of a segment.
    private var audioSegPTS: CMTime = .invalid

    /// The final path of the segment currently being written (so the pruner never
    /// deletes it). Read via `queue`.
    private(set) var activeFinalPath: String?

    init(cameraName: String, store: RecordingStore, recordAudio: Bool) {
        self.cameraName = cameraName
        self.store = store
        self.wantsAudio = recordAudio
        self.segmentSeconds = Double(max(1, store.settings.segmentSeconds))
        self.queue = DispatchQueue(label: "localvideo.recorder.\(RecordingStore.sanitize(cameraName))")
    }

    /// Record with an audio track only when the user asked for it AND the source has
    /// a codec we can mux (G.711). Recomputed each segment (config may arrive late).
    private var willWriteAudio: Bool { wantsAudio && (audioConfig?.isSupported ?? false) }

    // MARK: - Audio config (call on `queue`)

    func setAudioConfig(_ cfg: AudioStreamConfig) {
        if audioConfig?.isSupported != true { audioConfig = cfg }   // first usable config wins
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
                finalize(writer: writer, video: input, audio: audioInput, partial: currentPartial, final: currentFinal)
                startSegment(firstSample: sb, format: fmt, pts: pts)
                return
            }
        }
        appendSample(sb)
    }

    // MARK: - Segment lifecycle

    private func startSegment(firstSample sb: CMSampleBuffer, format fmt: CMFormatDescription, pts: CMTime) {
        // With audio we write a .mov (H.264 passthrough + PCM); video-only stays .mp4.
        let withAudio = willWriteAudio
        let ext = withAudio ? "mov" : "mp4"
        let fileType: AVFileType = withAudio ? .mov : .mp4
        guard let paths = store.segmentPaths(cameraName: cameraName, start: Date(), ext: ext) else { return }
        // A stale .partial (prior crash) at this exact path would block the writer.
        try? FileManager.default.removeItem(at: paths.partial)
        do {
            let w = try AVAssetWriter(outputURL: paths.partial, fileType: fileType)
            w.movieFragmentInterval = CMTime(value: 2, timescale: 1)   // fragment every ~2s → crash-resilient
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            inp.expectsMediaDataInRealTime = true
            guard w.canAdd(inp) else {
                NSLog("CameraRecorder[\(cameraName)]: cannot add video input"); return
            }
            w.add(inp)

            // Optional PCM audio track (from decoded G.711).
            var ainp: AVAssetWriterInput?
            if withAudio, let cfg = audioConfig {
                let afd = audioFormatDesc ?? Self.makePCMFormatDescription(cfg)
                audioFormatDesc = afd
                if let afd {
                    let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: afd)
                    a.expectsMediaDataInRealTime = true
                    if w.canAdd(a) { w.add(a); ainp = a }
                }
            }

            guard w.startWriting() else {
                NSLog("CameraRecorder[\(cameraName)]: startWriting failed: \(w.error?.localizedDescription ?? "?")"); return
            }
            w.startSession(atSourceTime: pts)
            writer = w; input = inp; audioInput = ainp
            currentPartial = paths.partial; currentFinal = paths.final
            currentFormat = fmt; segmentStartPTS = pts; audioSegPTS = .invalid
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

    // MARK: - Audio ingest (call on `queue`)

    /// Decode one G.711 packet to PCM and append it to the current segment's audio
    /// track. Dropped if audio isn't being written or the segment hasn't started yet.
    func appendAudio(_ data: Data) {
        guard active, willWriteAudio, let cfg = audioConfig,
              let ai = audioInput, let afd = audioFormatDesc,
              segmentStartPTS.isValid, ai.isReadyForMoreMediaData else { return }

        let pcm = G711.decode(data, format: cfg.format)
        let bytesPerFrame = max(1, 2 * cfg.channels)
        let numSamples = pcm.count / bytesPerFrame
        guard numSamples > 0 else { return }

        // Anchor the segment's audio near the video session start, then keep it
        // contiguous (sample-accurate) for smooth playback.
        if !audioSegPTS.isValid {
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            let anchor = CMTimeCompare(host, segmentStartPTS) < 0 ? segmentStartPTS : host
            audioSegPTS = CMTimeConvertScale(anchor, timescale: Int32(cfg.sampleRate), method: .roundHalfAwayFromZero)
        }
        let pts = audioSegPTS
        guard let sb = Self.makePCMSampleBuffer(pcm: pcm, numSamples: numSamples,
                                                bytesPerFrame: bytesPerFrame, formatDesc: afd,
                                                pts: pts, sampleRate: cfg.sampleRate) else { return }
        audioSegPTS = CMTimeAdd(pts, CMTime(value: Int64(numSamples), timescale: Int32(cfg.sampleRate)))
        if !ai.append(sb) {
            NSLog("CameraRecorder[\(cameraName)]: audio append failed: \(writer?.error?.localizedDescription ?? "?")")
        }
    }

    private static func makePCMFormatDescription(_ cfg: AudioStreamConfig) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(cfg.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * cfg.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * cfg.channels),
            mChannelsPerFrame: UInt32(cfg.channels),
            mBitsPerChannel: 16,
            mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        return fd
    }

    private static func makePCMSampleBuffer(pcm: Data, numSamples: Int, bytesPerFrame: Int,
                                            formatDesc: CMAudioFormatDescription, pts: CMTime,
                                            sampleRate: Int) -> CMSampleBuffer? {
        var bb: CMBlockBuffer?
        let n = pcm.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: n, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &bb) == kCMBlockBufferNoErr,
              let bb else { return nil }
        let copied = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: n) == kCMBlockBufferNoErr
        }
        guard copied else { return nil }

        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
                                          makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
                                          sampleCount: numSamples, sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                          sampleSizeArray: &sampleSize, sampleBufferOut: &sb)
        guard status == noErr else { return nil }
        return sb
    }

    /// Finalise a segment asynchronously: mark finished, flush, and rename
    /// `.partial → .mp4` on success (or delete a failed partial). Clears the "active"
    /// fields immediately so a new segment can open right away.
    private func finalize(writer: AVAssetWriter?, video: AVAssetWriterInput?, audio: AVAssetWriterInput?, partial: URL?, final: URL?) {
        self.writer = nil; self.input = nil; self.audioInput = nil
        self.currentPartial = nil; self.currentFinal = nil
        self.currentFormat = nil; self.segmentStartPTS = .invalid; self.audioSegPTS = .invalid
        self.activeFinalPath = nil
        guard let w = writer, let inp = video, let partial, let final else { return }
        inp.markAsFinished()
        audio?.markAsFinished()
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
                self.writer = nil; self.input = nil; self.audioInput = nil; self.activeFinalPath = nil
                completion?(); return
            }
            let ainp = self.audioInput
            self.writer = nil; self.input = nil; self.audioInput = nil
            self.currentPartial = nil; self.currentFinal = nil
            self.activeFinalPath = nil
            inp.markAsFinished()
            ainp?.markAsFinished()
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
