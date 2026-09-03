// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .executable(name: "NotchApp", targets: ["NotchApp"]),
        .executable(name: "NoolAgentBridge", targets: ["NoolAgentBridge"])
    ],
    targets: [
        .target(
            name: "NotchCore",
            path: "Sources/NotchCore"
        ),
        .executableTarget(
            name: "NotchApp",
            dependencies: ["NotchCore"],
            path: "Sources/NotchApp",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("SceneKit")
            ]
        ),
        .executableTarget(
            name: "NoolAgentBridge",
            path: "Sources/NoolAgentBridge"
        ),
        .testTarget(
            name: "NotchAppTests",
            dependencies: ["NotchApp"],
            path: "Tests/NotchAppTests"
        )
    ]
)
