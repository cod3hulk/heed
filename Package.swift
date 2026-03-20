// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Heed",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Heed",
            path: "Sources/Heed",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
