import Foundation
import SwiftData
import MetaWearPersistence

enum AppModelContainer {
    static func makeShared(inMemory: Bool = false) throws -> AppContainers {
        // v1: single local-only container. CloudKit for RememberedDevice is deferred
        // until the container schema is initialized in CloudKit Dashboard. To split
        // again later, give each ModelConfiguration a unique `name:` so they don't
        // both default to "default.store".
        let schema = Schema([
            RememberedDevice.self,
            MWSessionRecord.self,
            MWSampleRecord.self,
            LogSessionRecord.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        )
        return AppContainers(cloud: container, local: container)
    }
}
