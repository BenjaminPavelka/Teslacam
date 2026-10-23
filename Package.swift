// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TeslaPreview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TeslaPreview", targets: ["TeslaPreview"]),
    ],
    targets: [
        .target(name: "TeslaCamCore", swiftSettings: v5),
        .executableTarget(name: "TeslaPreview", dependencies: ["TeslaCamCore"], swiftSettings: v5),
        .testTarget(
            name: "TeslaCamCoreTests",
            dependencies: ["TeslaCamCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: v5
        ),
    ]
)
