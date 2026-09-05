// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VibeJuice",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "VibeJuice",
            path: "Sources/VibeJuice",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-parse-as-library"])]
        )
    ]
)
