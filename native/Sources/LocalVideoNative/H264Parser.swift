import Foundation
import CoreMedia

/// Parses an Annex-B H.264 elementary stream (as emitted by `ffmpeg -f h264`)
/// into CMSampleBuffers ready for AVSampleBufferDisplayLayer.
///
/// Annex-B frames each NAL unit with a start code (00 00 01, optionally with a
/// leading 00). We split on those, collect SPS (type 7) / PPS (type 8) to build
/// the CMVideoFormatDescription, and wrap each video slice NAL (types 1 and 5)
/// in AVCC framing (4-byte big-endian length prefix) inside a CMSampleBuffer.
final class H264Parser {

    /// Emitted for each decodable video slice. Called on the parser's queue.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var buffer = Data()
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var formatDesc: CMFormatDescription?
    /// Last presentation timestamp handed out, to keep PTS strictly increasing even
    /// when several frames are parsed within the same host-clock instant (bursts on
    /// connect). Non-monotonic timestamps make the muxed MP4's DTS invalid.
    private var lastPTS: CMTime = .invalid

    /// Append freshly read bytes and emit any complete sample buffers.
    func append(_ data: Data) {
        buffer.append(data)
        drainCompleteNALs()
    }

    // MARK: - NAL extraction

    /// Find start codes, extract every complete NAL, and keep the trailing
    /// (possibly incomplete) NAL in `buffer` for the next read.
    private func drainCompleteNALs() {
        let bytes = [UInt8](buffer)
        let n = bytes.count

        // Index just past each start code (the first byte of the NAL payload).
        var payloadStarts: [Int] = []
        // Index of the start-code's first 0x00 (the NAL before it ends here).
        var startCodeStarts: [Int] = []

        var i = 0
        while i + 3 <= n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                startCodeStarts.append(i)
                payloadStarts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }

        guard payloadStarts.count >= 1 else { return }

        // Each complete NAL runs from its payloadStart up to the next start code.
        // The final NAL is incomplete (no following start code yet) — defer it.
        var consumedUpTo = 0
        for idx in 0..<(payloadStarts.count - 1) {
            let start = payloadStarts[idx]
            let end = startCodeStarts[idx + 1]   // exclusive
            if end > start {
                handleNAL(Array(bytes[start..<end]))
            }
            consumedUpTo = startCodeStarts[idx + 1]
        }

        // Keep everything from the last start code onward (the pending NAL).
        if consumedUpTo > 0 {
            buffer.removeSubrange(0..<consumedUpTo)
        }
    }

    /// Strip trailing zero bytes (artifacts of 4-byte start codes / padding).
    private func trimTrailingZeros(_ nal: [UInt8]) -> [UInt8] {
        var end = nal.count
        while end > 0 && nal[end - 1] == 0 { end -= 1 }
        return Array(nal[0..<end])
    }

    private func handleNAL(_ rawNAL: [UInt8]) {
        let nal = trimTrailingZeros(rawNAL)
        guard let first = nal.first else { return }
        let type = first & 0x1F

        switch type {
        case 7:  // SPS
            sps = nal
            rebuildFormatDescription()
        case 8:  // PPS
            pps = nal
            rebuildFormatDescription()
        case 1, 5:  // non-IDR / IDR slice → a displayable picture
            guard let fmt = formatDesc else { return }  // wait for SPS+PPS first
            var pts = CMClockGetTime(CMClockGetHostTimeClock())
            if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 {
                pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: pts.timescale))  // keep it strictly increasing
            }
            lastPTS = pts
            if let sb = Self.makeSampleBuffer(nal: nal, formatDesc: fmt, isKeyframe: type == 5, pts: pts) {
                onSampleBuffer?(sb)
            }
        default:
            break  // AUD (9), SEI (6), etc. — not needed for display
        }
    }

    // MARK: - CoreMedia construction

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        var fmt: CMFormatDescription?
        sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                let pointers: [UnsafePointer<UInt8>] = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                let sizes: [Int] = [spsBuf.count, ppsBuf.count]
                pointers.withUnsafeBufferPointer { ptrs in
                    sizes.withUnsafeBufferPointer { szs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: szs.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt
                        )
                    }
                }
            }
        }
        if let fmt { formatDesc = fmt }
    }

    /// Wrap a single Annex-B NAL into an AVCC CMSampleBuffer tagged for immediate
    /// display. Also carries a host-clock presentation timestamp and a sync/keyframe
    /// flag: live display ignores both (DisplayImmediately overrides scheduling), but
    /// the recorder (AVAssetWriter passthrough) needs the timing + keyframe markers to
    /// mux a seekable, keyframe-aligned MP4. See docs/RECORDING_SPEC.md §4.
    private static func makeSampleBuffer(nal: [UInt8], formatDesc: CMFormatDescription, isKeyframe: Bool, pts: CMTime) -> CMSampleBuffer? {
        // AVCC framing: 4-byte big-endian length prefix + NAL bytes.
        let length = UInt32(nal.count)
        var avcc = [UInt8]()
        avcc.reserveCapacity(nal.count + 4)
        avcc.append(UInt8((length >> 24) & 0xFF))
        avcc.append(UInt8((length >> 16) & 0xFF))
        avcc.append(UInt8((length >> 8) & 0xFF))
        avcc.append(UInt8(length & 0xFF))
        avcc.append(contentsOf: nal)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // Host-clock presentation time (strictly increasing, set by the caller) so
        // the recorder can mux with real, monotonic timing. Display ignores it —
        // DisplayImmediately renders on arrival regardless.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid   // no B-frames → decode order == presentation order
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
            // Tag for immediate display — no presentation-time queueing.
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            // Mark non-IDR slices as not-sync so the recorder/players know keyframes.
            if !isKeyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        return sb
    }
}
