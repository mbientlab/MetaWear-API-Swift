import Foundation
import SwiftData
import MetaWearPersistence

enum AppModelContainer {
    static func makeShared(inMemory: Bool = false) throws -> AppContainers {
        // Single container synced to the user's private CloudKit database
        // (iCloud.com.mbientlab.MetaWear). All four models are CloudKit-compatible:
        // no `@Attribute(.unique)` constraints and every stored property is either
        // optional or has a default value, which CloudKit requires.
        //
        // The CloudKit container schema must be deployed to Production in the
        // CloudKit Dashboard before a TestFlight/App Store build will sync.
        //
        // In-memory mode (tests/previews) disables CloudKit, since an in-memory
        // store cannot be backed by CloudKit.
        let schema = Schema([
            RememberedDevice.self,
            MWSessionRecord.self,
            MWSampleRecord.self,
            LogSessionRecord.self
        ])
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = inMemory ? .none : .automatic
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudKitDatabase
            )
        )
        return AppContainers(cloud: container, local: container)
    }
}
