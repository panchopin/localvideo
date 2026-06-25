import Foundation
import AppKit

// ===========================================================================
// latency-probe — diagnostic CLI for LocalVideo stream latency.
//
// Tool A (implemented): stream health & regression — drift + FPS via a separate
// ffmpeg capture + Vision OCR of the camera's OSD clock. Never touches the app.
//
//   swift run latency-probe [--camera NAME] [--duration SECONDS] [--config PATH]
//
// Omit --camera to probe every configured camera sequentially.
// See docs/STREAM_LATENCY_EVALUATION.md for the full plan (Tool B = comparison).
// ===========================================================================

let args = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let cameraName = option("--camera")
let duration = Double(option("--duration") ?? "60") ?? 60
let configPath = option("--config")

// Tool B — app latency via the rendered window (ScreenCaptureKit + flip-edge).
//   swift run latency-probe screen [--window "LocalVideo"] [--duration 20] [--fps 10]
if args.contains("screen") {
    guard #available(macOS 12.3, *) else {
        FileHandle.standardError.write(Data("screen mode needs macOS 12.3+\n".utf8)); exit(1)
    }
    let window = option("--window") ?? "LocalVideo"
    let fps = Int(option("--fps") ?? "10") ?? 10
    let screenDuration = Double(option("--duration") ?? "20") ?? 20
    print("latency-probe — Tool B (app latency via window capture)\n")

    // ScreenCaptureKit requires a GUI (WindowServer) connection — a bare CLI
    // process triggers a CGS_REQUIRE_INIT assert. Establish an NSApplication and
    // run its loop, doing the capture on a background thread.
    let nsApp = NSApplication.shared
    nsApp.setActivationPolicy(.accessory)
    DispatchQueue.global(qos: .userInitiated).async {
        print("=== \(window) ===")
        ScreenProbe(windowQuery: window, duration: screenDuration, fps: fps).run()
        print("")
        exit(0)
    }
    nsApp.run()
}

let allCameras = ProbeConfig.load(explicit: configPath)
guard !allCameras.isEmpty else {
    FileHandle.standardError.write(Data("No cameras found in cameras.json\n".utf8))
    exit(1)
}

let selected = cameraName.map { name in allCameras.filter { $0.name == name } } ?? allCameras
guard !selected.isEmpty else {
    FileHandle.standardError.write(Data("No camera named \"\(cameraName ?? "")\". Configured: \(allCameras.map { $0.name }.joined(separator: ", "))\n".utf8))
    exit(1)
}

let ffmpeg = ProbeConfig.ffmpegPath()
print("latency-probe — Tool A (drift + FPS), \(Int(duration))s per camera\n")

for camera in selected {
    print("=== \(camera.name) ===")
    StreamProbe(name: camera.name, url: camera.resolvedURL, duration: duration, ffmpegPath: ffmpeg).run()
    print("")
}
