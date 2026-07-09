// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "XisperKeyboard",
  platforms: [.macOS(.v13)],
  targets: [
    .target(
      name: "XisperKeyboard",
      path: "Sources/XisperKeyboard",
      swiftSettings: [
        .unsafeFlags(["-parse-as-library"])
      ],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("Carbon"),
        .linkedFramework("AppKit"),
      ]
    )
  ]
)
