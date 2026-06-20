import Foundation
import SwiftData
import MetaWearPersistence

enum AppModelContainer {
    static func makeShared(inMemory: Bool = false) throws -> AppContainers {
        try AppContainers(
            cloud: makeRememberedDeviceContainer(inMemory: inMemory),
            local: makeLocalSessionContainer(inMemory: inMemory)
        )
    }

    private static func makeRememberedDeviceContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([RememberedDevice.self])
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = inMemory ? .none : .automatic
        let configuration = ModelConfiguration(
            "RememberedDevices",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudKitDatabase
        )

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch where !inMemory {
            // iCloud backup is deliberately best-effort. If the CloudKit-backed
            // store cannot initialize (for example: account/capability problems
            // during development), keep the app usable with a local remembered
            // device store instead of blocking launch.
            let fallback = ModelConfiguration(
                "RememberedDevicesLocalFallback",
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: fallback)
        }
    }

    private static func makeLocalSessionContainer(inMemory: Bool) throws -> ModelContainer {
        // Keep high-volume telemetry out of CloudKit. Local SwiftData owns all
        // sessions, samples, and active logging records so live streaming and
        // downloads stay fast regardless of iCloud availability.
        let schema = Schema([
            MWSessionRecord.self,
            MWSampleRecord.self,
            LogSessionRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: configuration
        )
    }
}
