// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spacelight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Spacelight",
            path: "Sources/Spacelight",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "SpacelightTests",
            dependencies: ["Spacelight"],
            path: "Tests/SpacelightTests"
        ),
    ]
)
