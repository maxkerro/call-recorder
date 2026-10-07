// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CallRecorder",
            path: "Sources/CallRecorder"
        )
    ],
    swiftLanguageModes: [.v5]
)
