// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalVideoNative",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalVideoNative",
            path: "Sources/LocalVideoNative"
        )
    ],
    // Phase 1 uses background pipe reads + main-thread UI hops; Swift 5 language
    // mode keeps that pragmatic without fighting strict-concurrency checks yet.
    swiftLanguageModes: [.v5]
)
