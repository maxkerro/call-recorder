// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "CallRecorder",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/CallRecorder"
        )
    ],
    swiftLanguageModes: [.v5]
)
