// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SpeedTest",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpeedTest",
            path: "Sources/SpeedTest"
        )
    ]
)
