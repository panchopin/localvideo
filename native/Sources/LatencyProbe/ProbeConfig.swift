import Foundation

/// Minimal, read-only view of a camera entry for the probe. Intentionally
/// self-contained (does not depend on the app target) so the diagnostic tool
/// can't destabilize the product.
struct ProbeCamera: Decodable {
    let name: String
    let url: String
    let username: String?
    let password: String?

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

private struct CamerasFile: Decodable { let cameras: [ProbeCamera] }

enum ProbeConfig {
    /// Mirror of the app's path resolution: explicit arg, else repo-relative, else
    /// the bundled app's Application Support location.
    static func resolveConfigPath(explicit: String?) -> String {
        if let explicit { return explicit }
        for path in ["cameras.json", "../cameras.json"] where FileManager.default.fileExists(atPath: path) {
            return path
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("LocalVideo/cameras.json").path
    }

    static func load(explicit: String?) -> [ProbeCamera] {
        let path = resolveConfigPath(explicit: explicit)
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONDecoder().decode(CamerasFile.self, from: data) else { return [] }
        return parsed.cameras
    }

    static func ffmpegPath() -> String {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/ffmpeg"
    }
}
