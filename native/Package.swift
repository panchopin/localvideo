// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalVideoNative",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalVideoNative",
            path: "Sources/LocalVideoNative"
        ),
        // Diagnostic latency probe (Tool A: stream drift + FPS). Separate target so
        // it never touches the app's render path. See docs/STREAM_LATENCY_EVALUATION.md.
        .executableTarget(
            name: "latency-probe",
            path: "Sources/LatencyProbe"
        )
    ],
    // Phase 1 uses background pipe reads + main-thread UI hops; Swift 5 language
    // mode keeps that pragmatic without fighting strict-concurrency checks yet.
    swiftLanguageModes: [.v5]
)
