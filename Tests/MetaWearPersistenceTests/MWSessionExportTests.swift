import Testing
import SwiftData
import Foundation
@testable import MetaWear
@testable import MetaWearPersistence

private func makeStore() throws -> MWPersistenceStore {
    let container = try MWPersistenceStore.makeContainer(inMemory: true)
    return MWPersistenceStore(modelContainer: container)
}

private func makeDeviceInfo() -> MWDeviceInformation {
    MWDeviceInformation(manufacturer: "MbientLab", modelNumber: "4",
                        serialNumber: "AA:BB", firmwareRevision: "1.7.0", hardwareRevision: "0.4")
}

@Suite("MWPersistenceStore — CSV export")
struct MWSessionExportTests {

    @Test func exportTable_cartesian_columnHeaders() async throws {
        let store = try makeStore()
        let samples = (0..<3).map {
            MWLoggedSample(date: Date(timeIntervalSince1970: Double($0)), tickMs: Double($0) * 10,
                           value: CartesianFloat(x: Float($0), y: 0, z: 0))
        }
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: samples)
        let table = try await store.exportTable(sessionID: snap.id, as: CartesianFloat.self)
        #expect(table.columns == ["epoch", "elapsed_ms", "x", "y", "z"])
    }

    @Test func exportTable_quaternion_columnHeaders() async throws {
        let store = try makeStore()
        let s = [MWLoggedSample(date: Date(), tickMs: 0, value: Quaternion(w: 1, x: 0, y: 0, z: 0))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: Quaternion.persistenceKind, samples: s)
        let table = try await store.exportTable(sessionID: snap.id, as: Quaternion.self)
        #expect(table.columns == ["epoch", "elapsed_ms", "w", "x", "y", "z"])
    }

    @Test func exportTable_rowCount_matchesSampleCount() async throws {
        let store = try makeStore()
        let count = 7
        let samples = (0..<count).map {
            MWLoggedSample(date: Date(timeIntervalSince1970: Double($0)), tickMs: Double($0),
                           value: CartesianFloat(x: 0, y: 0, z: 0))
        }
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: samples)
        let table = try await store.exportTable(sessionID: snap.id, as: CartesianFloat.self)
        #expect(table.rows.count == count)
    }

    @Test func exportTable_csvString_lineCount() async throws {
        let store = try makeStore()
        let count = 5
        let samples = (0..<count).map {
            MWLoggedSample(date: Date(timeIntervalSince1970: Double($0)), tickMs: Double($0),
                           value: CartesianFloat(x: 0, y: 0, z: 0))
        }
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind,
                                               samples: samples)
        let table = try await store.exportTable(sessionID: snap.id, as: CartesianFloat.self)
        let lines = table.csvString.components(separatedBy: "\n")
        // 1 header + count data rows
        #expect(lines.count == count + 1)
    }

    @Test func exportTable_epoch_isISO8601() async throws {
        let store = try makeStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let s = [MWLoggedSample(date: date, tickMs: 0, value: CartesianFloat(x: 0, y: 0, z: 0))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind, samples: s)
        let table = try await store.exportTable(sessionID: snap.id, as: CartesianFloat.self)
        let epochField = table.rows[0][0]
        let parsed = ISO8601DateFormatter().date(from: epochField)
        #expect(parsed != nil, "epoch column should be a valid ISO8601 date string, got: \(epochField)")
    }

    @Test func exportTable_elapsedMs_isCorrect() async throws {
        let store = try makeStore()
        let s = [MWLoggedSample(date: Date(), tickMs: 12345.678,
                                value: CartesianFloat(x: 0, y: 0, z: 0))]
        let snap = try await store.saveSession(deviceID: UUID(), deviceInfo: makeDeviceInfo(),
                                               sensorKind: CartesianFloat.persistenceKind, samples: s)
        let table = try await store.exportTable(sessionID: snap.id, as: CartesianFloat.self)
        #expect(table.rows[0][1] == "12345.678")
    }
}
