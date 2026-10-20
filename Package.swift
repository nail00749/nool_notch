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
        .executable(name: "NoolAgentBridge", targets: ["NoolAgentBridge"]),
        .executable(name: "NoolDockRecovery", targets: ["NoolDockRecovery"]),
        .library(
            name: "NoolMediaRemoteAdapter",
            type: .dynamic,
            targets: ["NoolMediaRemoteAdapter"]
        )
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
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("SceneKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "NoolAgentBridge",
            path: "Sources/NoolAgentBridge"
        ),
        .executableTarget(
            name: "NoolDockRecovery",
            dependencies: ["NotchCore"],
            path: "Sources/NoolDockRecovery"
        ),
        .target(
            name: "NoolMediaRemoteAdapter",
            path: "Sources/NoolMediaRemoteAdapter",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "NotchAppTests",
            dependencies: ["NotchApp"],
            path: "Tests/NotchAppTests"
        )
    ]
)
