import Foundation
import SwiftData
import MetaWearPersistence
import os

enum AppModelContainer {

    /// Persistence-setup logger. CloudKit availability problems are otherwise
    /// invisible — the fallback below deliberately keeps the app functional
    /// without iCloud, which once made a broken sync setup indistinguishable
    /// from a working one. Filter Console/Xcode output on "MetaWearPersistence".
    private static let log = Logger(
        subsystem: "com.mbientlab.MetaWear",
        category: "MetaWearPersistence"
    )
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
            let container = try ModelContainer(for: schema, configurations: configuration)
            if !inMemory {
                // Note: a missing/denied iCloud account does NOT throw here —
                // SwiftData initializes fine and sync just never runs. When
                // diagnosing "devices don't appear on my other device", also
                // check CoreData's own CloudKit console output.
                log.info("RememberedDevices store opened with CloudKit enabled.")
            }
            return container
        } catch where !inMemory {
            // iCloud backup is deliberately best-effort. If the CloudKit-backed
            // store can't initialize (account/capability problems), reopen the
            // SAME on-disk store locally with CloudKit off. Reusing the same
            // configuration name ("RememberedDevices") matters: a different name
            // points at a separate SQLite file, orphaning any already-synced
            // remembered devices in a divergent store.
            log.error("""
            RememberedDevices CloudKit store failed to open — falling back to \
            local-only. Remembered devices will NOT sync on this install. \
            Error: \(error, privacy: .public)
            """)
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
