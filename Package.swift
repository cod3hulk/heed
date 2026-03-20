// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Heed",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "Heed",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Heed",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
