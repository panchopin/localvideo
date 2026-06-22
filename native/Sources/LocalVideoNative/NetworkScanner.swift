import Foundation
import Darwin

/// A camera-like RTSP endpoint found on the local network.
struct DiscoveredCamera: Equatable {
    let host: String
    let port: Int
    var path: String?       // resolved stream path, if a common one matched
    var needsAuth: Bool      // DESCRIBE returned 401 → credentials required
}

/// Discovers RTSP streams by sweeping the local /24 for open RTSP ports, then
/// confirming each with an RTSP OPTIONS request and trying common stream paths
/// via DESCRIBE. No ONVIF/Bonjour — those found nothing on this network; bare
/// RTSP endpoints (like these cameras) only answer on their stream port.
enum NetworkScanner {

    /// Common vendor stream paths, ordered roughly by prevalence.
    private static let commonPaths = [
        "/live", "/stream1", "/stream2", "/h264", "/ch0", "/ch01",
        "/cam/realmonitor?channel=1&subtype=0", "/Streaming/Channels/101",
        "/live/ch00_0", "/video1", "/media/video1", "/axis-media/media.amp",
        "/11", "/onvif1", "/",
    ]
    private static let scanPorts = [554, 8554]

    /// Run a full scan off the main thread. `progress` and `completion` are
    /// delivered on the main queue. `configured` holds "host:port" strings
    /// already in use, which are filtered out of the results.
    static func scan(configured: Set<String>,
                     progress: @escaping (Int, Int) -> Void,
                     completion: @escaping ([DiscoveredCamera]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let prefix = localIPv4Prefix() else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let hosts = (1...254).map { "\(prefix).\($0)" }
            let total = hosts.count * scanPorts.count
            let lock = NSLock()
            var openHostPorts: [(String, Int)] = []
            var done = 0

            let sem = DispatchSemaphore(value: 64)
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .userInitiated)

            for host in hosts {
                for port in scanPorts {
                    sem.wait()
                    group.enter()
                    queue.async {
                        defer { sem.signal(); group.leave() }
                        if let fd = connectSocket(host: host, port: port, timeout: 0.3) {
                            close(fd)
                            lock.lock(); openHostPorts.append((host, port)); lock.unlock()
                        }
                        lock.lock(); done += 1; let d = done; lock.unlock()
                        if d % 25 == 0 || d == total {
                            DispatchQueue.main.async { progress(d, total) }
                        }
                    }
                }
            }

            group.notify(queue: queue) {
                var results: [DiscoveredCamera] = []
                for (host, port) in openHostPorts.sorted(by: { $0.0 < $1.0 }) {
                    if configured.contains("\(host):\(port)") { continue }
                    // Confirm it actually speaks RTSP.
                    guard let optStatus = rtspStatus(host: host, port: port, method: "OPTIONS", path: "/", timeout: 1.0),
                          [200, 401, 405].contains(optStatus) else { continue }
                    // Best-effort path resolution.
                    var foundPath: String?
                    var needsAuth = false
                    for path in commonPaths {
                        guard let status = rtspStatus(host: host, port: port, method: "DESCRIBE", path: path, timeout: 0.8) else { continue }
                        if status == 200 { foundPath = path; needsAuth = false; break }
                        if status == 401 { foundPath = path; needsAuth = true; break }
                    }
                    results.append(DiscoveredCamera(host: host, port: port, path: foundPath, needsAuth: needsAuth))
                }
                DispatchQueue.main.async { completion(results) }
            }
        }
    }

    // MARK: - Low-level helpers

    /// Derive the local IPv4 /24 prefix (e.g. "192.168.0"), preferring en0.
    private static func localIPv4Prefix() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var best: String?
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, Int(MemoryLayout<sockaddr_in>.size))
            let ip = String(cString: inet_ntoa(sin.sin_addr))
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254") { continue }
            let name = String(cString: p.pointee.ifa_name)
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            if name == "en0" { return prefix }   // prefer primary interface
            if best == nil { best = prefix }
        }
        return best
    }

    /// Non-blocking connect with a timeout. Returns a connected (blocking) fd or nil.
    private static func connectSocket(host: String, port: Int, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc != 0 {
            if errno != EINPROGRESS { close(fd); return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, Int32(timeout * 1000)) <= 0 { close(fd); return nil }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)   // restore blocking
        return fd
    }

    /// Send an RTSP request and return the numeric status code (or nil).
    private static func rtspStatus(host: String, port: Int, method: String, path: String, timeout: TimeInterval) -> Int? {
        guard let fd = connectSocket(host: host, port: port, timeout: timeout) else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request = "\(method) rtsp://\(host):\(port)\(path) RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: LocalVideo\r\nAccept: application/sdp\r\n\r\n"
        let bytes = Array(request.utf8)
        let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }
        guard sent > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }

        let response = String(decoding: buf[0..<n], as: UTF8.self)
        guard let line = response.split(separator: "\r\n", maxSplits: 1).first, line.hasPrefix("RTSP/") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        return code
    }
}
