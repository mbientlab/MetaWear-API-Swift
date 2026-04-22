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
        .executable(name: "MetaWearDemo", targets: ["MetaWearDemo"])
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
            name: "MetaWearHardwareTests",
            dependencies: ["MetaWear"],
            path: "Tests/MetaWearHardwareTests"
        ),
    ]
)
