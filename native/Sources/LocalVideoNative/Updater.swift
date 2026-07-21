import AppKit

// ===========================================================================
// In-app updater — consults the PUBLIC GitHub repo's Releases.
//
// The release pipeline (.github/workflows/release.yml) publishes a self-contained
// `LocalVideo-vX.Y.Z.zip` asset for every `vX.Y.Z` tag. This checks the latest
// release, and if it's newer than the running app it downloads the zip, swaps the
// running .app bundle in place, and relaunches. No auth needed (public repo).
// ===========================================================================

enum Updater {
    static let repo = "panchopin/localvideo"
    private static let latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// The running app's marketing version (Info.plist CFBundleShortVersionString).
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    struct Release {
        let tag: String          // "v0.2.0"
        let version: String      // "0.2.0" (tag without leading "v")
        let notes: String        // release body (may be empty)
        let zipURL: URL          // browser_download_url of the .app zip
        let htmlURL: URL         // the release page (manual-download fallback)
    }

    enum UpdaterError: LocalizedError {
        case noAsset
        case badResponse(Int)
        case notABundle
        case notWritable(String)
        case unzipFailed(String)
        case bundleMissing

        var errorDescription: String? {
            switch self {
            case .noAsset:            return "The latest release has no downloadable app."
            case .badResponse(let c): return "GitHub returned an unexpected response (HTTP \(c))."
            case .notABundle:         return "This build isn't running from an .app bundle, so it can't self-update. Open the release page to download manually."
            case .notWritable(let d): return "LocalVideo can't update itself here — \(d) isn't writable. Move the app somewhere you own (e.g. /Applications or your home folder), or download it manually."
            case .unzipFailed(let s): return "Could not unpack the update: \(s)"
            case .bundleMissing:      return "The downloaded update didn't contain LocalVideo.app."
            }
        }
    }

    // MARK: - Check

    /// Fetch the latest release. Completion runs on the main thread.
    static func fetchLatestRelease(completion: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("LocalVideo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, error in
            func finish(_ r: Result<Release, Error>) { DispatchQueue.main.async { completion(r) } }
            if let error { return finish(.failure(error)) }
            guard let http = response as? HTTPURLResponse else {
                return finish(.failure(UpdaterError.badResponse(-1)))
            }
            guard (200..<300).contains(http.statusCode), let data else {
                return finish(.failure(UpdaterError.badResponse(http.statusCode)))
            }
            do {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String,
                      let htmlStr = obj["html_url"] as? String,
                      let html = URL(string: htmlStr) else {
                    return finish(.failure(UpdaterError.badResponse(http.statusCode)))
                }
                let assets = obj["assets"] as? [[String: Any]] ?? []
                guard let zip = assets.compactMap({ $0["browser_download_url"] as? String })
                        .first(where: { $0.hasSuffix(".zip") }),
                      let zipURL = URL(string: zip) else {
                    return finish(.failure(UpdaterError.noAsset))
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let notes = (obj["body"] as? String) ?? ""
                finish(.success(Release(tag: tag, version: version, notes: notes, zipURL: zipURL, htmlURL: html)))
            } catch {
                finish(.failure(error))
            }
        }.resume()
    }

    /// True when `candidate` is a strictly higher semantic version than `current`.
    /// Compares dot-separated numeric components (missing components treated as 0);
    /// non-numeric parts sort as 0 so we never crash on an odd tag.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download + install

    /// Download the release zip to a temp file. Progress (0...1) and completion run
    /// on the main thread.
    static func download(_ release: Release,
                         progress: @escaping (Double) -> Void,
                         completion: @escaping (Result<URL, Error>) -> Void) {
        let delegate = DownloadDelegate(progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var req = URLRequest(url: release.zipURL)
        req.setValue("LocalVideo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: req).resume()
    }

    /// Unpack the zip, verify it holds LocalVideo.app, then hand off to a detached
    /// shell script that waits for THIS process to quit, swaps the bundle in place,
    /// and relaunches. On success this terminates the app and does not return.
    static func installAndRelaunch(zipAt zipURL: URL) throws {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { throw UpdaterError.notABundle }

        // Bail early (before quitting) if we can't replace the bundle in place.
        let parentDir = (bundlePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parentDir) else { throw UpdaterError.notWritable(parentDir) }

        let work = fm.temporaryDirectory.appendingPathComponent("LocalVideoUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // Unzip with ditto (handles the ditto-created archive from the release job).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, work.path]
        let errPipe = Pipe()
        unzip.standardError = errPipe
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
            throw UpdaterError.unzipFailed(msg)
        }

        // Find the unpacked LocalVideo.app (top level, or one dir down).
        guard let newApp = findApp(in: work, fm: fm) else { throw UpdaterError.bundleMissing }

        // Detached swap-and-relaunch script. Lives in its OWN temp file (NOT inside
        // `work`, which it deletes). Moves the old bundle aside first and rolls back
        // if the copy fails, so a failed update never leaves the user with no app.
        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = shq(bundlePath)
        let src = shq(newApp.path)
        let backup = shq(bundlePath + ".old")
        let script = """
        #!/bin/sh
        # Wait for LocalVideo (pid \(pid)) to quit, then swap the bundle and relaunch.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf \(backup)
        /bin/mv \(dest) \(backup) || exit 1
        if /usr/bin/ditto \(src) \(dest) && [ -x \(dest)/Contents/MacOS/LocalVideo ]; then
            /bin/rm -rf \(backup)
        else
            /bin/rm -rf \(dest)
            /bin/mv \(backup) \(dest)   # roll back to the working app
        fi
        /usr/bin/xattr -dr com.apple.quarantine \(dest) 2>/dev/null
        /bin/rm -rf \(shq(work.path)) \(shq(zipURL.path))
        /usr/bin/open \(dest)
        """
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("LocalVideoSwap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = [scriptURL.path]
        try swap.run()   // detached: we don't wait

        // Quit so the script can replace us.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Locate LocalVideo.app inside `dir` (top level or immediate subdirectories).
    private static func findApp(in dir: URL, fm: FileManager) -> URL? {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let top = items.first(where: { $0.lastPathComponent == "LocalVideo.app" }) { return top }
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
               let hit = nested.first(where: { $0.lastPathComponent == "LocalVideo.app" }) {
                return hit
            }
        }
        return nil
    }

    /// Single-quote a path for safe embedding in the /bin/sh script.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// URLSession download delegate that reports progress and hands back the file.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    let completion: (Result<URL, Error>) -> Void
    private var done = false

    init(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move out of the session's temp location before it's reaped.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalVideo-update-\(UUID().uuidString).zip")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            done = true
            DispatchQueue.main.async { self.completion(.success(dest)) }
        } catch {
            done = true
            DispatchQueue.main.async { self.completion(.failure(error)) }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !done {
            done = true
            DispatchQueue.main.async { self.completion(.failure(error)) }
        }
        session.finishTasksAndInvalidate()
    }
}
