// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CUA",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CUA",
            targets: ["CUA"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.15.0")
        // mlx-audio-swift blocked by swift-transformers version conflict with WhisperKit.
        // TTSBackend protocol is in place — add Kokoro when versions align.
    ],
    targets: [
        .executableTarget(
            name: "CUA",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/CUA",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
