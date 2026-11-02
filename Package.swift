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
        .library(name: "NoolCoolingCore", targets: ["NoolCoolingCore"]),
        .executable(name: "NoolCoolingHelper", targets: ["NoolCoolingHelper"]),
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
        .target(
            name: "NoolCoolingCore",
            path: "Sources/NoolCoolingCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "NoolCoolingHelper",
            dependencies: ["NoolCoolingCore"],
            path: "Sources/NoolCoolingHelper",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "NotchApp",
            dependencies: ["NotchCore", "NoolCoolingCore"],
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
            name: "NoolCoolingCoreTests",
            dependencies: ["NoolCoolingCore"],
            path: "Tests/NoolCoolingCoreTests"
        ),
        .testTarget(
            name: "NotchAppTests",
            dependencies: ["NotchApp"],
            path: "Tests/NotchAppTests"
        )
    ]
)
