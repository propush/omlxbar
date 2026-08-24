// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "omlxbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "omlxbar",
            path: "Sources/omlxbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "omlxbarTests",
            dependencies: ["omlxbar"],
            path: "Tests/omlxbarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
