import Foundation
import SwiftData
import MetaWearPersistence

enum AppModelContainer {
    static func makeShared(inMemory: Bool = false) throws -> AppContainers {
        // v1 ships **local-only** (no CloudKit). CloudKit was tried but
        // `NSPersistentCloudKitContainer` on the app's main `ModelContext`
        // thrashed the main actor at runtime (continuous WAL checkpoints +
        // failed `com.apple.coredata.cloudkit.activity.export` background-task
        // scheduling), which stalled the interactive @MainActor flows — single
        // reads, the Live-Stream "Add sensor" menu, and logging start. Raw BLE
        // streaming (which doesn't touch SwiftData) was unaffected, which is the
        // tell. CloudKit sync is not required for v1.
        //
        // The models remain CloudKit-compatible (optional relationships, no
        // `@Attribute(.unique)`, defaults on every stored property), so
        // re-enabling later is a one-line flip back to `.automatic` — but only
        // after the proper setup: register `BGTaskSchedulerPermittedIdentifiers`
        // for `com.apple.coredata.cloudkit.activity`, route writes through a
        // dedicated background context, and deploy the schema to Production.
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
