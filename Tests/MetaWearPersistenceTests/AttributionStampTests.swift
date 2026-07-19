import Testing
import SwiftData
import Foundation
@testable import MetaWear
@testable import MetaWearPersistence

// MARK: - Attribution stamps (group-logging prebake)
//
// deviceName / sampleCount / groupID are stamped at SAVE time because they
// cannot be reconstructed later: peripheral UUIDs are per-host and boards go
// off air (no retroactive name), and a group batch only exists at capture.
// Data written without these fields can never be backfilled — which is why
// the stamps land ahead of the group-logging feature itself.

@Suite("MWPersistenceStore — attribution stamps")
struct AttributionStampTests {

    private func makeStore() throws -> MWPersistenceStore {
        let container = try MWPersistenceStore.makeContainer(inMemory: true)
        return MWPersistenceStore(modelContainer: container)
    }

    private func info() -> MWDeviceInformation {
        MWDeviceInformation(
            manufacturer: "MbientLab Inc.",
            modelNumber: "8",
            serialNumber: "0123FF",
            firmwareRevision: "1.7.2",
            hardwareRevision: "0.4"
        )
    }

    private func samples(_ count: Int) -> [MWLoggedSample<CartesianFloat>] {
        (0..<count).map { i in
            MWLoggedSample(
                date: Date(timeIntervalSince1970: Double(i)),
                tickMs: Double(i) * 10,
                value: CartesianFloat(x: 0, y: 0, z: 1)
            )
        }
    }

    @Test func saveStampsNameCountAndGroup() async throws {
        let store = try makeStore()
        let group = UUID()
        let snap = try await store.saveSession(
            deviceID: UUID(),
            deviceInfo: info(),
            sensorKind: CartesianFloat.persistenceKind,
            samples: samples(7),
            label: "Accelerometer · ±2g · 100 Hz",
            deviceName: "bob",
            groupID: group
        )
        #expect(snap.deviceName == "bob")
        #expect(snap.sampleCount == 7)
        #expect(snap.groupID == group)

        // Round-trips through a fresh fetch, not just the save-path snapshot.
        let fetched = try #require(try await store.fetchAllSessions().first)
        #expect(fetched.deviceName == "bob")
        #expect(fetched.sampleCount == 7)
        #expect(fetched.groupID == group)
    }

    /// A missed advertisement can hand the app "" as the display name —
    /// the save choke point must normalise it to nil so readers' fallbacks
    /// (serial keys, section titles) fire instead of rendering blanks.
    @Test func emptyDeviceNameNormalisesToNil() async throws {
        let store = try makeStore()
        let snap = try await store.saveSession(
            deviceID: UUID(),
            deviceInfo: info(),
            sensorKind: CartesianFloat.persistenceKind,
            samples: samples(2),
            deviceName: ""
        )
        #expect(snap.deviceName == nil)
    }

    @Test func stampsDefaultToNilForSoloSessions() async throws {
        let store = try makeStore()
        let snap = try await store.saveSession(
            deviceID: UUID(),
            deviceInfo: info(),
            sensorKind: CartesianFloat.persistenceKind,
            samples: samples(3)
        )
        #expect(snap.deviceName == nil)
        #expect(snap.groupID == nil)
        #expect(snap.sampleCount == 3)
    }

    /// Pre-migration records carry `sampleCount == 0` — the snapshot must
    /// fall back to counting the samples relationship, not report zero.
    @Test func snapshotFallsBackToCountingForLegacyRecords() throws {
        let container = try MWPersistenceStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let record = MWSessionRecord(
            deviceID: UUID(),
            sensorKind: CartesianFloat.persistenceKind,
            startDate: .now,
            endDate: .now,
            deviceSerial: "0123FF",
            deviceModel: "8",
            deviceFirmware: "1.7.2"
        )
        context.insert(record)
        for i in 0..<4 {
            let sample = MWSampleRecord(
                date: .now, tickMs: Double(i),
                f0: 0, f1: 0, f2: 0, f3: 0
            )
            sample.session = record
            context.insert(sample)
        }
        try context.save()
        let snap = MWSessionSnapshot(record: record)
        #expect(snap.sampleCount == 4)
        #expect(snap.deviceName == nil)
    }
}
