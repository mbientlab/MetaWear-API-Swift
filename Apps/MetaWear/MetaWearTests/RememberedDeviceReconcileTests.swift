import Foundation
import Testing
import SwiftData
@testable import MetaWearApp

/// Covers `AppStore.reconcileRememberedDevice` — the cross-host identity
/// logic that matches a connecting board to its synced record.
///
/// CoreBluetooth peripheral UUIDs are host-specific, so a record synced from
/// another Apple device can only be recognized by MAC address. The reconciler
/// must prefer the MAC match and fold UUID-keyed duplicates.
@MainActor
@Suite("RememberedDevice reconciliation")
struct RememberedDeviceReconcileTests {

    /// Held for the suite instance's lifetime: a `ModelContext` does NOT keep
    /// its `ModelContainer` alive, and touching a context whose container was
    /// released crashes inside SwiftData.
    private let containers: AppContainers
    private var context: ModelContext { containers.cloud.mainContext }

    init() throws {
        containers = try AppModelContainer.makeShared(inMemory: true)
    }

    @Test
    func matchesByUUIDWhenNoMAC() throws {
        let id = UUID()
        context.insert(RememberedDevice(peripheralUUID: id, name: "MetaWear"))
        try context.save()

        let found = AppStore.reconcileRememberedDevice(
            in: context, peripheralUUID: id, macAddress: nil
        )
        #expect(found?.peripheralUUID == id)
    }

    @Test
    func matchesByMACWhenUUIDIsForeign() throws {
        // Record created on another host: its peripheralUUID means nothing
        // here, but the MAC identifies the same physical board.
        let foreignID = UUID()
        context.insert(RememberedDevice(
            peripheralUUID: foreignID,
            name: "MetaWear",
            macAddress: "F1:4A:04:29:26:8B"
        ))
        try context.save()

        let found = AppStore.reconcileRememberedDevice(
            in: context, peripheralUUID: UUID(), macAddress: "F1:4A:04:29:26:8B"
        )
        #expect(found?.peripheralUUID == foreignID)
    }

    @Test
    func foldsUUIDDuplicateIntoMACRecord() throws {
        // The board was remembered on this host before MAC backfill existed
        // (UUID row, no MAC) AND on another host (MAC row). Reconciling must
        // keep the MAC row — other hosts may reference it — and delete the
        // local duplicate.
        let localID = UUID()
        let foreignID = UUID()
        context.insert(RememberedDevice(peripheralUUID: localID, name: "MetaWear"))
        context.insert(RememberedDevice(
            peripheralUUID: foreignID,
            name: "MetaWear",
            macAddress: "F1:4A:04:29:26:8B"
        ))
        try context.save()

        let found = AppStore.reconcileRememberedDevice(
            in: context, peripheralUUID: localID, macAddress: "F1:4A:04:29:26:8B"
        )
        try context.save()

        #expect(found?.peripheralUUID == foreignID)
        let all = try context.fetch(FetchDescriptor<RememberedDevice>())
        #expect(all.count == 1)
        #expect(all.first?.macAddress == "F1:4A:04:29:26:8B")
    }

    @Test
    func returnsNilWhenUnknown() throws {
        let found = AppStore.reconcileRememberedDevice(
            in: context, peripheralUUID: UUID(), macAddress: "AA:BB:CC:DD:EE:FF"
        )
        #expect(found == nil)
    }

    @Test
    func uuidMatchStillWinsWithUnknownMAC() throws {
        // Same board reconnecting on its original host, MAC previously
        // unset and no other row claims it: fall back to the UUID match
        // (whose macAddress the caller then backfills).
        let id = UUID()
        context.insert(RememberedDevice(peripheralUUID: id, name: "MetaWear"))
        try context.save()

        let found = AppStore.reconcileRememberedDevice(
            in: context, peripheralUUID: id, macAddress: "F1:4A:04:29:26:8B"
        )
        #expect(found?.peripheralUUID == id)
    }
}
