import Foundation

/// One camera entry in cameras.json (shared with the Python viewer).
///
/// `id` is a stable identity used to diff config changes — so renaming or
/// re-ordering a camera doesn't needlessly restart a healthy stream. It is
/// generated on first save and is optional on read (backward compatible with
/// the older schema that had no id).
struct CameraConfig: Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var username: String?
    var password: String?
    /// Whether this camera streams in the main grid. When false the app does not
    /// connect it or render a tile — it stays configured but hidden. Defaults to
    /// true and is backward-compatible (absent in older cameras.json ⇒ shown).
    var showVideoStream: Bool
    /// Whether this camera is continuously recorded to disk. A camera streams (has
    /// a live RTSPSource) when `showVideoStream || recordVideo`, so recording works
    /// even for a camera hidden from the grid. Defaults to false; backward-compatible.
    var recordVideo: Bool
    /// Whether to also record audio (decoded G.711 → PCM in a .mov) when recordVideo
    /// is on. Defaults to false; backward-compatible.
    var recordAudio: Bool

    enum CodingKeys: String, CodingKey { case id, name, url, username, password, showVideoStream, recordVideo, recordAudio }

    init(id: UUID = UUID(), name: String, url: String, username: String? = nil, password: String? = nil, showVideoStream: Bool = true, recordVideo: Bool = false, recordAudio: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.showVideoStream = showVideoStream
        self.recordVideo = recordVideo
        self.recordAudio = recordAudio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.username = try? c.decode(String.self, forKey: .username)
        self.password = try? c.decode(String.self, forKey: .password)
        // Backward compatible: an older file without the key means "shown".
        self.showVideoStream = (try? c.decode(Bool.self, forKey: .showVideoStream)) ?? true
        self.recordVideo = (try? c.decode(Bool.self, forKey: .recordVideo)) ?? false
        self.recordAudio = (try? c.decode(Bool.self, forKey: .recordAudio)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encode(showVideoStream, forKey: .showVideoStream)
        try c.encode(recordVideo, forKey: .recordVideo)
        try c.encode(recordAudio, forKey: .recordAudio)
    }

    /// Full RTSP(S) URL with credentials inserted if they were supplied
    /// separately. Handles both rtsp:// and rtsps:// schemes.
    var resolvedURL: String {
        guard let user = username, !user.isEmpty,
              let pass = password, !pass.isEmpty else { return url }
        for scheme in ["rtsps://", "rtsp://"] {
            if let range = url.range(of: scheme, options: .caseInsensitive) {
                var result = url
                result.replaceSubrange(range, with: "\(scheme)\(user):\(pass)@")
                return result
            }
        }
        return url
    }
}

/// Global recording settings (the `recording` block in cameras.json). All fields
/// are optional on read so an older file (or a partial block) falls back to
/// defaults. See docs/RECORDING_SPEC.md §7.
struct RecordingSettings: Equatable {
    var directory: String
    var retentionHours: Int
    var segmentSeconds: Int

    /// ~/Movies/LocalVideo, keep 48h, 60s segments.
    static var `default`: RecordingSettings {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Movies")
        return RecordingSettings(
            directory: movies.appendingPathComponent("LocalVideo", isDirectory: true).path,
            retentionHours: 48,
            segmentSeconds: 60
        )
    }
}

extension RecordingSettings: Codable {
    enum CodingKeys: String, CodingKey { case directory, retentionHours, segmentSeconds }

    init(from decoder: Decoder) throws {
        let d = RecordingSettings.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.directory = (try? c.decode(String.self, forKey: .directory)).flatMap { $0.isEmpty ? nil : $0 } ?? d.directory
        self.retentionHours = (try? c.decode(Int.self, forKey: .retentionHours)).flatMap { $0 > 0 ? $0 : nil } ?? d.retentionHours
        self.segmentSeconds = (try? c.decode(Int.self, forKey: .segmentSeconds)).flatMap { $0 > 0 ? $0 : nil } ?? d.segmentSeconds
    }
}

private struct CamerasFile: Codable {
    let cameras: [CameraConfig]
    let recording: RecordingSettings?
}

enum Config {
    /// Resolve the cameras.json path. An explicit arg wins (dev runs). Otherwise
    /// prefer a repo-relative file when running from source, else fall back to
    /// the user's Application Support directory (the home for a bundled .app).
    static func resolveConfigPath(explicit: String?) -> String {
        if let explicit { return explicit }
        for path in ["cameras.json", "../cameras.json"] where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return appSupportConfigPath()
    }

    /// ~/Library/Application Support/LocalVideo/cameras.json (created if needed).
    private static func appSupportConfigPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("LocalVideo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cameras.json").path
    }

    /// Load the camera list from a path (empty if missing/invalid).
    static func load(from path: String) -> [CameraConfig] {
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONDecoder().decode(CamerasFile.self, from: data) else {
            return []
        }
        return parsed.cameras
    }

    /// Load the global recording settings (defaults if missing/invalid).
    static func loadRecording(from path: String) -> RecordingSettings {
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONDecoder().decode(CamerasFile.self, from: data) else {
            return .default
        }
        return parsed.recording ?? .default
    }

    /// Persist the camera list + recording settings atomically (write-temp-then-
    /// rename). Always writes `url` / `username` / `password` separately — never
    /// `resolvedURL`.
    static func save(_ cameras: [CameraConfig], recording: RecordingSettings, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CamerasFile(cameras: cameras, recording: recording))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
