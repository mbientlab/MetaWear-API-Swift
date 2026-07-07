import Foundation
import Testing
import SwiftData
@testable import MetaWearApp

/// Covers `AppStore.dedupeRememberedDevices` — the sweep that folds duplicate
/// rows CloudKit can produce (no unique constraints; sync-state resets
/// re-import server rows next to their local twins).
@MainActor
@Suite("RememberedDevice dedupe")
struct RememberedDeviceDedupeTests {

    private let containers: AppContainers
    private var context: ModelContext { containers.cloud.mainContext }

    init() throws {
        containers = try AppModelContainer.makeShared(inMemory: true)
    }

    private func fetchAll() throws -> [RememberedDevice] {
        try context.fetch(FetchDescriptor<RememberedDevice>())
    }

    @Test
    func foldsSamePeripheralUUIDTwins() throws {
        // The exact shape from the field: a CloudKit reset resurrected a row,
        // leaving two records with identical peripheralUUID and no MAC.
        let id = UUID()
        context.insert(RememberedDevice(
            peripheralUUID: id, name: "MetaWear",
            lastConnected: Date(timeIntervalSince1970: 100)
        ))
        context.insert(RememberedDevice(
            peripheralUUID: id, name: "MetaWear",
            lastConnected: Date(timeIntervalSince1970: 200)
        ))
        try context.save()

        let survivors = AppStore.dedupeRememberedDevices(try fetchAll(), in: context)
        try context.save()

        #expect(survivors.count == 1)
        #expect(survivors.first?.lastConnected == Date(timeIntervalSince1970: 200))
        #expect(try fetchAll().count == 1)
    }

    @Test
    func foldsSameMACTwinsAndMergesFields() throws {
        // Two hosts remembered the same board before either synced: same MAC,
        // different peripheral UUIDs, complementary fields.
        context.insert(RememberedDevice(
            peripheralUUID: UUID(), name: "MetaWear",
            macAddress: "ED:AA:A4:CE:A6:A4",
            lastConnected: Date(timeIntervalSince1970: 300),
            serialNumber: nil, firmwareRevision: "1.7.2", modelNumber: nil
        ))
        context.insert(RememberedDevice(
            peripheralUUID: UUID(), name: "MetaWear",
            macAddress: "ED:AA:A4:CE:A6:A4",
            lastConnected: Date(timeIntervalSince1970: 100),
            serialNumber: "0648AF", firmwareRevision: nil, modelNumber: "5"
        ))
        try context.save()

        let survivors = AppStore.dedupeRememberedDevices(try fetchAll(), in: context)
        try context.save()

        #expect(survivors.count == 1)
        let keeper = try #require(survivors.first)
        #expect(keeper.lastConnected == Date(timeIntervalSince1970: 300))
        // Fields the keeper lacked came over from the folded twin.
        #expect(keeper.serialNumber == "0648AF")
        #expect(keeper.firmwareRevision == "1.7.2")
        #expect(keeper.modelNumber == "5")
    }

    @Test
    func foldsMACLessTwinIntoMACBearingKeeperByUUID() throws {
        // Pre-backfill row (no MAC) + the same board's post-backfill row
        // sharing the peripheral UUID.
        let id = UUID()
        context.insert(RememberedDevice(
            peripheralUUID: id, name: "MetaWear",
            lastConnected: Date(timeIntervalSince1970: 100)
        ))
        context.insert(RememberedDevice(
            peripheralUUID: id, name: "MetaWear",
            macAddress: "ED:AA:A4:CE:A6:A4",
            lastConnected: Date(timeIntervalSince1970: 100)
        ))
        try context.save()

        let survivors = AppStore.dedupeRememberedDevices(try fetchAll(), in: context)
        try context.save()

        #expect(survivors.count == 1)
        #expect(survivors.first?.macAddress == "ED:AA:A4:CE:A6:A4")
    }

    @Test
    func distinctBoardsAreUntouched() throws {
        context.insert(RememberedDevice(
            peripheralUUID: UUID(), name: "MetaWear",
            macAddress: "ED:AA:A4:CE:A6:A4", lastConnected: .now
        ))
        context.insert(RememberedDevice(
            peripheralUUID: UUID(), name: "MetaWear",
            macAddress: "F1:4A:04:29:26:8B", lastConnected: .now
        ))
        context.insert(RememberedDevice(
            peripheralUUID: UUID(), name: "MetaWear", lastConnected: .now
        ))
        try context.save()

        let survivors = AppStore.dedupeRememberedDevices(try fetchAll(), in: context)
        #expect(survivors.count == 3)
    }

    @Test
    func keeperChoiceIsDeterministicRegardlessOfInputOrder() throws {
        // Same data, both orders → same survivor. This is what keeps multiple
        // hosts from deleting different twins and never converging.
        let id = UUID()
        let a = RememberedDevice(
            peripheralUUID: id, name: "A",
            lastConnected: Date(timeIntervalSince1970: 500)
        )
        let b = RememberedDevice(
            peripheralUUID: id, name: "B",
            lastConnected: Date(timeIntervalSince1970: 400)
        )
        context.insert(a)
        context.insert(b)
        try context.save()

        let forward = AppStore.dedupeRememberedDevices([a, b], in: context)
        #expect(forward.first?.name == "A")
        // (b was deleted; a survives regardless of visit order because the
        // precedence tuple compares identically.)
        let reversed = AppStore.dedupeRememberedDevices([a], in: context)
        #expect(reversed.first?.name == "A")
    }
}
