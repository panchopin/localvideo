import Foundation
import Vision
import ImageIO
import CoreGraphics

struct OSDReading {
    let time: Date        // OSD wall time mapped to the day nearest `now`
    let confidence: Float
    let raw: String
}

/// Reads the camera's burned-in clock via on-device OCR (Apple Vision).
///
/// v1 OCRs the whole frame and picks the bottom-right-most `HH:MM:SS` match — no
/// per-camera ROI calibration needed, since the OSD clock is normally the only
/// time-shaped text on screen.
enum OSDReader {
    // Accept common OCR confusions of the ':' separator (/, ., ;) but not '-'
    // (the burned-in date uses dashes, e.g. 2026-06-23).
    private static let timeRegex = try! NSRegularExpression(pattern: #"(\d{1,2})[:/.;](\d{2})[:/.;](\d{2})"#)

    static func read(pngData: Data, now: Date) -> OSDReading? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            if ProcessInfo.processInfo.environment["OSD_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[ocr] decode failed (\(pngData.count) bytes)\n".utf8))
            }
            return nil
        }
        return read(cgImage: cg, now: now)
    }

    static func read(cgImage: CGImage, now: Date) -> OSDReading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observations = request.results else { return nil }

        if ProcessInfo.processInfo.environment["OSD_DEBUG"] != nil {
            let strings = observations.compactMap { $0.topCandidates(1).first?.string }
            FileHandle.standardError.write(Data("[ocr] \(strings)\n".utf8))
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

            // Prefer the bottom-right observation (boundingBox origin is bottom-left).
            let bb = obs.boundingBox
            let score = Double(bb.maxX) + Double(1 - bb.minY)
            if score > bestScore {
                bestScore = score
                best = OSDReading(time: date, confidence: candidate.confidence, raw: text)
            }
        }
        return best
    }

    /// Map h:m:s to a full Date, choosing yesterday/today/tomorrow nearest `now`
    /// so a clock reading near midnight doesn't jump ~24 h.
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
}
