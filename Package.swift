// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VolumeBar",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "VolumeBar", targets: ["VolumeBar"])],
    targets: [
        .target(name: "AudioDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "VolumeBar", dependencies: ["AudioDSP"], linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("CoreAudio"), .linkedFramework("AVFoundation")
        ]),
        .testTarget(name: "AudioDSPTests", dependencies: ["AudioDSP"]),
        .testTarget(name: "DeviceTests", dependencies: ["VolumeBar"])
    ]
)
