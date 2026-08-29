// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scale2Health",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "Scale2HealthCore", targets: ["Scale2HealthCore"])
    ],
    targets: [
        .target(
            name: "Scale2HealthCore",
            path: "Scale2Health",
            exclude: [
                "App",
                "UI",
                "Assets.xcassets",
                "Info.plist",
                "Scale2Health.entitlements",
                "Managers/BluetoothManager.swift",
                "Managers/HealthKitManager.swift",
                "Managers/AppModel.swift",
                "Protocol/BS444_PROTOCOL.md"
            ],
            sources: [
                "Models/BodyMeasurement.swift",
                "Models/ScaleDevice.swift",
                "Models/MeasurementDeduplicator.swift",
                "Managers/DeviceStore.swift",
                "Protocol/BS444Protocol.swift",
                "Protocol/BS444Parser.swift"
            ]
        ),
        .executableTarget(
            name: "Scale2HealthCoreChecks",
            dependencies: ["Scale2HealthCore"],
            path: "Scale2HealthChecks"
        ),
        .testTarget(
            name: "Scale2HealthCoreTests",
            dependencies: ["Scale2HealthCore"],
            path: "Scale2HealthTests",
            exclude: [
                "BS444ParserTests.swift",
                "ModelTests.swift",
                "LinuxMain.swift"
            ],
            sources: ["PackageSmokeTests.swift"]
        )
    ]
)
