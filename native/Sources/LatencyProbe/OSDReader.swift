import Foundation
import Vision
import ImageIO
import CoreGraphics
import CoreVideo

struct OSDReading {
    let time: Date        // OSD wall time mapped to the day nearest `now`
    let confidence: Float
    let raw: String
}

/// Reads the camera's burned-in clock via on-device OCR (Apple Vision).
///
/// OCRs the whole image and picks the bottom-right-most time match — no
/// per-camera ROI calibration needed, since the OSD clock is normally the only
/// time-shaped text present.
enum OSDReader {
    // Accept common OCR confusions of the ':' separator (/, ., ;) but not '-'
    // (the burned-in date uses dashes, e.g. 2026-06-23).
    private static let timeRegex = try! NSRegularExpression(pattern: #"(\d{1,2})[:/.;](\d{2})[:/.;](\d{2})"#)

    /// OCR a PNG (Tool A) — accurate level, decoded via ImageIO.
    static func read(pngData: Data, now: Date) -> OSDReading? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            debug("decode failed (\(pngData.count) bytes)")
            return nil
        }
        return perform(VNImageRequestHandler(cgImage: cg, options: [:]), now: now, level: .accurate)
    }

    /// OCR a captured pixel buffer (Tool B) — caller picks the level (.fast for
    /// the high-frame-rate flip-edge capture).
    static func read(pixelBuffer: CVPixelBuffer, now: Date, level: VNRequestTextRecognitionLevel) -> OSDReading? {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]), now: now, level: level)
    }

    // MARK: - Core

    private static func perform(_ handler: VNImageRequestHandler, now: Date, level: VNRequestTextRecognitionLevel) -> OSDReading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        do { try handler.perform([request]) } catch { return nil }
        guard let observations = request.results else { return nil }

        if ProcessInfo.processInfo.environment["OSD_DEBUG"] != nil {
            debug("\(observations.compactMap { $0.topCandidates(1).first?.string })")
        }

        var best: OSDReading?
        var bestScore = -Double.greatestFiniteMagnitude
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            let nsText = text as NSString
            guard let match = timeRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { continue }
            func group(_ i: Int) -> Int { Int(nsText.substring(with: match.range(at: i))) ?? -1 }
            let h = group(1), m = group(2), s = group(3)
            guard (0...23).contains(h), (0...59).contains(m), (0...59).contains(s),
                  let date = mapToDay(h: h, m: m, s: s, near: now) else { continue }
            let bb = obs.boundingBox   // origin bottom-left
            let score = Double(bb.maxX) + Double(1 - bb.minY)   // bottom-right preference
            if score > bestScore {
                bestScore = score
                best = OSDReading(time: date, confidence: candidate.confidence, raw: text)
            }
        }
        return best
    }

    private static func mapToDay(h: Int, m: Int, s: Int, near now: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = h; comps.minute = m; comps.second = s
        guard let base = cal.date(from: comps) else { return nil }
        let day: TimeInterval = 86_400
        return [base.addingTimeInterval(-day), base, base.addingTimeInterval(day)]
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    private static func debug(_ s: String) {
        if ProcessInfo.processInfo.environment["OSD_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[ocr] \(s)\n".utf8))
        }
    }
}
