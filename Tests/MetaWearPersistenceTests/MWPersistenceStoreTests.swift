import Testing
import SwiftData
import Foundation
@testable import MetaWear
@testable import MetaWearPersistence

// MARK: - Helpers

private func makeStore() throws -> MWPersistenceStore {
    let container = try MWPersistenceStore.makeContainer(inMemory: true)
    return MWPersistenceStore(modelContainer: container)
}

private func makeDeviceInfo(serial: String = "AA:BB:CC:DD:EE:FF") -> MWDeviceInformation {
    MWDeviceInformation(
        manufacturer: "MbientLab Inc.",
        modelNumber: "4",
        serialNumber: serial,
        firmwareRevision: "1.7.0",
        hardwareRevision: "0.4"
    )
}

private func cartesianSamples(count: Int, startTickMs: Double = 0) -> [MWLoggedSample<CartesianFloat>] {
    (0..<count).map { i in
        MWLoggedSample(
            date: Date(timeIntervalSince1970: Double(i)),
            tickMs: startTickMs + Double(i) * 10.0,
            value: CartesianFloat(x: Float(i) * 0.1, y: Float(i) * 0.2, z: Float(i) * 0.3)
        )
    }
}

// MARK: - Save / fetch basics

@Suite("MWPersistenceStore — save and fetch")
struct MWPersistenceStoreTests {

    @Test func saveSession_returnsSnapshot() async throws {
        let store = try makeStore()
        let id = UUID()
        let samples = cartesianSamples(count: 5)
        let snapshot = try await store.saveSession(
            deviceID: id,
            deviceInfo: makeDeviceInfo(),
            sensorKind: CartesianFloat.persistenceKind,
            samples: samples)
        #expect(snapshot.deviceID == id)
        #expect(snapshot.sensorKind == CartesianFloat.persistenceKind)
        #expect(snapshot.sampleCount == 5)
    }

    @Test func saveSession_emptySamples_throws() async throws {
        let store = try makeStore()
        let empty: [MWLoggedSample<CartesianFloat>] = []
        await #expect(throws: MWPersistenceError.emptySampleSet) {
            try await store.saveSession(
                deviceID: UUID(),
                deviceInfo: makeDeviceInfo(),
                sensorKind: CartesianFloat.persistenceKind,
                samples: empty)
        }
    }

    @Test func fetchSessions_returnsOnlyMatchingDevice() async throws {
        let store = try makeStore()
        let deviceA = UUID()
        let deviceB = UUID()

        _ = try await store.saveSession(deviceID: deviceA, deviceInfo: makeDeviceInfo(),
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 3))
        _ = try await store.saveSession(deviceID: deviceB, deviceInfo: makeDeviceInfo(),
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 3))

        let resultA = try await store.fetchSessions(deviceID: deviceA)
        let resultB = try await store.fetchSessions(deviceID: deviceB)
        #expect(resultA.count == 1)
        #expect(resultB.count == 1)
        #expect(resultA[0].deviceID == deviceA)
        #expect(resultB[0].deviceID == deviceB)
    }

    @Test func fetchSessions_sortedNewestFirst() async throws {
        let store = try makeStore()
        let deviceID = UUID()
        let info = makeDeviceInfo()

        let older = [MWLoggedSample(date: Date(timeIntervalSince1970: 1000), tickMs: 0,
                                    value: CartesianFloat(x: 0, y: 0, z: 0))]
        let newer = [MWLoggedSample(date: Date(timeIntervalSince1970: 2000), tickMs: 0,
                                    value: CartesianFloat(x: 1, y: 1, z: 1))]

        _ = try await store.saveSession(deviceID: deviceID, deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind, samples: older)
        _ = try await store.saveSession(deviceID: deviceID, deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind, samples: newer)

        let sessions = try await store.fetchSessions(deviceID: deviceID)
        #expect(sessions.count == 2)
        #expect(sessions[0].startDate > sessions[1].startDate)
    }

    @Test func fetchAllSessions_emptyStore_returnsEmpty() async throws {
        let store = try makeStore()
        let all = try await store.fetchAllSessions()
        #expect(all.isEmpty)
    }

    @Test func fetchAllSessions_returnsAcrossDevices() async throws {
        let store = try makeStore()
        let info = makeDeviceInfo()
        _ = try await store.saveSession(deviceID: UUID(), deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 1))
        _ = try await store.saveSession(deviceID: UUID(), deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 1))
        let all = try await store.fetchAllSessions()
        #expect(all.count == 2)
    }

    @Test func saveSession_storesDeviceInfo() async throws {
        let store = try makeStore()
        let info = makeDeviceInfo(serial: "11:22:33:44:55:66")
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: info,
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: cartesianSamples(count: 1))
        #expect(snap.deviceSerial == "11:22:33:44:55:66")
        #expect(snap.deviceModel  == "4")
        #expect(snap.deviceFirmware == "1.7.0")
    }
}

// MARK: - Sample round-trips

@Suite("MWPersistenceStore — sample round-trips")
struct MWPersistenceStoreRoundTripTests {

    @Test func cartesian_roundTrip() async throws {
        let store = try makeStore()
        let original = cartesianSamples(count: 3)
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: original)

        let restored = try await store.fetchSamples(sessionID: snap.id, as: CartesianFloat.self)
        #expect(restored.count == 3)
        for (o, r) in zip(original, restored) {
            #expect(abs(r.value.x - o.value.x) < 1e-5)
            #expect(abs(r.value.y - o.value.y) < 1e-5)
            #expect(abs(r.value.z - o.value.z) < 1e-5)
            #expect(abs(r.tickMs  - o.tickMs)  < 1e-9)
        }
    }

    @Test func quaternion_roundTrip() async throws {
        let store = try makeStore()
        let original = [MWLoggedSample(
            date: Date(), tickMs: 123.456,
            value: Quaternion(w: 0.707, x: 0.0, y: 0.707, z: 0.0))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: Quaternion.persistenceKind,
                                               samples: original)

        let restored = try await store.fetchSamples(sessionID: snap.id, as: Quaternion.self)
        #expect(restored.count == 1)
        #expect(abs(restored[0].value.w - 0.707) < 1e-5)
        #expect(abs(restored[0].value.y - 0.707) < 1e-5)
        #expect(abs(restored[0].tickMs  - 123.456) < 1e-9)
    }

    @Test func eulerAngles_roundTrip() async throws {
        let store = try makeStore()
        let original = [MWLoggedSample(
            date: Date(), tickMs: 0,
            value: EulerAngles(heading: 45, pitch: -10, roll: 5, yaw: 90))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: EulerAngles.persistenceKind,
                                               samples: original)

        let restored = try await store.fetchSamples(sessionID: snap.id, as: EulerAngles.self)
        #expect(abs(restored[0].value.heading - 45)  < 1e-5)
        #expect(abs(restored[0].value.pitch   - (-10)) < 1e-5)
        #expect(abs(restored[0].value.roll    - 5)   < 1e-5)
        #expect(abs(restored[0].value.yaw     - 90)  < 1e-5)
    }

    @Test func correctedCartesian_roundTrip_preservesAccuracy() async throws {
        let store = try makeStore()
        let original = [MWLoggedSample(
            date: Date(), tickMs: 0,
            value: CorrectedCartesianFloat(x: 1, y: 2, z: 3, accuracy: 3))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CorrectedCartesianFloat.persistenceKind,
                                               samples: original)

        let restored = try await store.fetchSamples(sessionID: snap.id,
                                                    as: CorrectedCartesianFloat.self)
        #expect(restored[0].value.accuracy == 3)
    }

    @Test func float_roundTrip() async throws {
        let store = try makeStore()
        let original = [MWLoggedSample(date: Date(), tickMs: 0, value: Float(23.5))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: Float.persistenceKind,
                                               samples: original)

        let restored = try await store.fetchSamples(sessionID: snap.id, as: Float.self)
        #expect(abs(restored[0].value - 23.5) < 1e-5)
    }

    @Test func bool_roundTrip() async throws {
        let store = try makeStore()
        let original = [
            MWLoggedSample(date: Date(timeIntervalSince1970: 0), tickMs: 0, value: true),
            MWLoggedSample(date: Date(timeIntervalSince1970: 1), tickMs: 10, value: false),
        ]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: Bool.persistenceKind,
                                               samples: original)

        let restored = try await store.fetchSamples(sessionID: snap.id, as: Bool.self)
        #expect(restored.count == 2)
        #expect(restored[0].value == true)
        #expect(restored[1].value == false)
    }

    @Test func fetchSamples_sortedByTickMs() async throws {
        let store = try makeStore()
        // Insert samples in reverse tick order — fetch must return them sorted ascending
        let scrambled = [
            MWLoggedSample(date: Date(timeIntervalSince1970: 2), tickMs: 20,
                           value: CartesianFloat(x: 2, y: 0, z: 0)),
            MWLoggedSample(date: Date(timeIntervalSince1970: 0), tickMs: 0,
                           value: CartesianFloat(x: 0, y: 0, z: 0)),
            MWLoggedSample(date: Date(timeIntervalSince1970: 1), tickMs: 10,
                           value: CartesianFloat(x: 1, y: 0, z: 0)),
        ]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: scrambled)

        let restored = try await store.fetchSamples(sessionID: snap.id, as: CartesianFloat.self)
        #expect(restored[0].tickMs < restored[1].tickMs)
        #expect(restored[1].tickMs < restored[2].tickMs)
    }

    @Test func fetchSamples_kindMismatch_throws() async throws {
        let store = try makeStore()
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: cartesianSamples(count: 1))

        await #expect(throws: MWPersistenceError.self) {
            _ = try await store.fetchSamples(sessionID: snap.id, as: Quaternion.self)
        }
    }

    @Test func fetchSamples_unknownID_throws() async throws {
        let store = try makeStore()
        // Save and delete so we have a valid PersistentIdentifier shape but the record is gone
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: cartesianSamples(count: 1))
        try await store.deleteSession(id: snap.id)

        await #expect(throws: MWPersistenceError.self) {
            _ = try await store.fetchSamples(sessionID: snap.id, as: CartesianFloat.self)
        }
    }
}

// MARK: - Delete

@Suite("MWPersistenceStore — delete")
struct MWPersistenceStoreDeleteTests {

    @Test func deleteSession_removesIt() async throws {
        let store = try makeStore()
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: cartesianSamples(count: 2))
        try await store.deleteSession(id: snap.id)
        let all = try await store.fetchAllSessions()
        #expect(all.isEmpty)
    }

    @Test func deleteAllSessions_onlyRemovesMatchingDevice() async throws {
        let store = try makeStore()
        let deviceA = UUID()
        let deviceB = UUID()
        let info    = makeDeviceInfo()

        _ = try await store.saveSession(deviceID: deviceA, deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 1))
        _ = try await store.saveSession(deviceID: deviceB, deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 1))

        try await store.deleteAllSessions(for: deviceA)

        let remainingA = try await store.fetchSessions(deviceID: deviceA)
        let remainingB = try await store.fetchSessions(deviceID: deviceB)
        #expect(remainingA.isEmpty)
        #expect(remainingB.count == 1)
    }

    @Test func deleteAll_clearsEverything() async throws {
        let store = try makeStore()
        let info = makeDeviceInfo()
        _ = try await store.saveSession(deviceID: UUID(), deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 1))
        _ = try await store.saveSession(deviceID: UUID(), deviceInfo: info,
                                        sensorKind: CartesianFloat.persistenceKind,
                                        samples: cartesianSamples(count: 1))
        try await store.deleteAll()
        let all = try await store.fetchAllSessions()
        #expect(all.isEmpty)
    }
}
