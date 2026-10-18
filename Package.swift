// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BiliMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BiliMac",
            path: "Sources/BiliMac",
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
    ]
)
