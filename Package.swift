// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DupeFixer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "dupefix", targets: ["DupeFixer"])
    ],
    targets: [
        .executableTarget(
            name: "DupeFixer",
            path: "Sources/DupeFixer"
        ),
        .testTarget(
            name: "DupeFixerTests",
            dependencies: ["DupeFixer"],
            path: "Tests/DupeFixerTests"
        )
    ]
)
