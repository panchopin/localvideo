import Foundation

/// Owns the on-disk layout for recordings and the retention sweep.
///
/// Layout (local time):  {base}/{camera}/{YYYY-MM}/{DD}/{HH}/{camera}-{YYYYMMDD_HHMMSS}.mp4
/// A segment being written uses a `.mp4.partial` suffix until finalised, so the
/// pruner and any future playback never touch a half-written file.
/// See docs/RECORDING_SPEC.md §9, §12.
final class RecordingStore {

    private(set) var settings: RecordingSettings

    init(settings: RecordingSettings) { self.settings = settings }

    func updateSettings(_ new: RecordingSettings) { settings = new }

    var baseDirectory: URL { URL(fileURLWithPath: settings.directory, isDirectory: true) }

    // MARK: - Path construction

    // Fixed, locale-independent numeric formatting in LOCAL time.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }
    private static let monthFmt = formatter("yyyy-MM")
    private static let dayFmt   = formatter("dd")
    private static let hourFmt  = formatter("HH")
    private static let stampFmt = formatter("yyyyMMdd_HHmmss")

    /// Build (and create the directory for) the segment paths for a camera at a
    /// given start time. Returns the `.partial` path to write to and the final
    /// `.mp4` path to rename to on finalisation. Nil if the directory can't be made.
    func segmentPaths(cameraName: String, start: Date) -> (partial: URL, final: URL)? {
        let safe = Self.sanitize(cameraName)
        let dir = baseDirectory
            .appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent(Self.monthFmt.string(from: start), isDirectory: true)
            .appendingPathComponent(Self.dayFmt.string(from: start), isDirectory: true)
            .appendingPathComponent(Self.hourFmt.string(from: start), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("RecordingStore: could not create \(dir.path): \(error.localizedDescription)")
            return nil
        }
        let base = "\(safe)-\(Self.stampFmt.string(from: start)).mp4"
        let final = dir.appendingPathComponent(base)
        return (final.appendingPathExtension("partial"), final)
    }

    /// Filesystem-safe camera name: strip path separators / colon / control chars,
    /// collapse whitespace, and never allow an empty or dot-only name.
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dropped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return dropped.isEmpty ? "camera" : cleaned
    }

    // MARK: - Retention

    /// Delete recordings older than the retention window, then prune emptied
    /// directories. `activePaths` are never deleted (segments currently being
    /// written). Safe to call on a background queue; failures are logged, not fatal.
    func prune(activePaths: Set<String>) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionHours) * 3600)
        guard let base = try? fm.contentsOfDirectory(at: baseDirectory,
                                                     includingPropertiesForKeys: nil) else { return }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        for cameraDir in base {
            guard let e = fm.enumerator(at: cameraDir, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in e {
                guard url.pathExtension == "mp4" else { continue }          // skip .partial and dirs
                if activePaths.contains(url.path) { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
            pruneEmptyDirectories(under: cameraDir)
        }
    }

    /// Remove empty directories bottom-up under `root` (but keep `root` itself).
    private func pruneEmptyDirectories(under root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: []) else { return }
        // Collect dirs, then delete deepest-first so parents empty out.
        var dirs: [URL] = []
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                dirs.append(url)
            }
        }
        for dir in dirs.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// Free space (bytes) on the recordings volume, or nil if unknown.
    func freeSpaceBytes() -> Int64? {
        let values = try? baseDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
