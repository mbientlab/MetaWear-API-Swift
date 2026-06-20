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
            // store can't initialize (account/capability problems), reopen the
            // SAME on-disk store locally with CloudKit off. Reusing the same
            // configuration name ("RememberedDevices") matters: a different name
            // points at a separate SQLite file, orphaning any already-synced
            // remembered devices in a divergent store.
            let fallback = ModelConfiguration(
                "RememberedDevices",
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
