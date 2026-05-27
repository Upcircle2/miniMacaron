// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "miniMacaron",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "miniMacaron",
            path: "Sources/miniMacaron"
        )
    ]
)
