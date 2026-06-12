// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MetaWear",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "MetaWear", targets: ["MetaWear"]),
        .library(name: "MetaWearPersistence", targets: ["MetaWearPersistence"]),
        // Firmware update (DFU) lives in its own product so apps that don't
        // need over-the-air firmware updates don't pull in NordicDFU + its
        // ZIPFoundation transitive dependency.
        .library(name: "MetaWearFirmware", targets: ["MetaWearFirmware"]),
        .executable(name: "MetaWearDemo", targets: ["MetaWearDemo"])
    ],
    dependencies: [
        // Nordic Semiconductor's iOS DFU library — handles the actual
        // chunked-transfer + CRC-verify protocol once the board is in
        // bootloader mode. Pinned to 4.16.0 (latest as of 2026-05; same SPM
        // URL and module name `NordicDFU` as 4.11). Library is still
        // delegate-based (no async/await) and not Swift 6 concurrency-aware,
        // so we wrap it in our own actor-isolated `DFUSession` and import
        // it `@preconcurrency` from the firmware target.
        .package(
            url: "https://github.com/NordicSemiconductor/IOS-DFU-Library",
            exact: "4.16.0"
        )
    ],
    targets: [
        .target(
            name: "MetaWear",
            path: "Sources/MetaWear"
        ),
        .target(
            name: "MetaWearPersistence",
            dependencies: ["MetaWear"],
            path: "Sources/MetaWearPersistence"
        ),
        .target(
            name: "MetaWearFirmware",
            dependencies: [
                "MetaWear",
                .product(name: "NordicDFU", package: "IOS-DFU-Library")
            ],
            path: "Sources/MetaWearFirmware"
        ),
        .executableTarget(
            name: "MetaWearDemo",
            dependencies: ["MetaWear"],
            path: "Sources/MetaWearDemo",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MetaWearTests",
            dependencies: ["MetaWear"],
            path: "Tests/MetaWearTests"
        ),
        .testTarget(
            name: "MetaWearPersistenceTests",
            dependencies: ["MetaWearPersistence", "MetaWear"],
            path: "Tests/MetaWearPersistenceTests"
        ),
        .testTarget(
            name: "MetaWearFirmwareTests",
            dependencies: ["MetaWearFirmware", "MetaWear"],
            path: "Tests/MetaWearFirmwareTests"
        ),
        .testTarget(
            name: "MetaWearHardwareTests",
            dependencies: ["MetaWear"],
            path: "Tests/MetaWearHardwareTests"
        ),
    ]
)
