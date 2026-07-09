// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XisperContext",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "XisperContext", type: .dynamic, targets: ["XisperContext"]),
    ],
    targets: [
        .target(
            name: "XisperContext",
            path: "Sources/XisperContext",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
