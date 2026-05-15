// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Heed",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "HeedCore",
            path: "Sources/HeedCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Heed",
            dependencies: [
                "HeedCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Heed",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "HeedTests",
            dependencies: ["HeedCore"],
            path: "Tests/HeedTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
