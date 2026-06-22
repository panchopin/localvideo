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

    enum CodingKeys: String, CodingKey { case id, name, url, username, password }

    init(id: UUID = UUID(), name: String, url: String, username: String? = nil, password: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.username = try? c.decode(String.self, forKey: .username)
        self.password = try? c.decode(String.self, forKey: .password)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(password, forKey: .password)
    }

    /// Full RTSP URL with credentials inserted if they were supplied separately.
    var resolvedURL: String {
        guard let user = username, !user.isEmpty,
              let pass = password, !pass.isEmpty else { return url }
        guard let range = url.range(of: "rtsp://") else { return url }
        var result = url
        result.replaceSubrange(range, with: "rtsp://\(user):\(pass)@")
        return result
    }
}

private struct CamerasFile: Codable {
    let cameras: [CameraConfig]
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

    /// Persist the camera list atomically (write-temp-then-rename). Always
    /// writes `url` / `username` / `password` separately — never `resolvedURL`.
    static func save(_ cameras: [CameraConfig], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CamerasFile(cameras: cameras))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
