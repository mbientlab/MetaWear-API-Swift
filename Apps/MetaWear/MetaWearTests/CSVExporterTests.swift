import Foundation
import Testing
import MetaWear
import MetaWearPersistence
@testable import MetaWearApp

@MainActor
@Suite("CSVExporter")
struct CSVExporterTests {

    @Test func exportsCorrectedCartesianSamples() async throws {
        let container = try AppModelContainer.makeShared(inMemory: true).local
        let store = MWPersistenceStore(modelContainer: container)
        let info = MWDeviceInformation(
            manufacturer: "MbientLab",
            modelNumber: "MetaWear",
            serialNumber: "TEST",
            firmwareRevision: "1.0.0",
            hardwareRevision: "1"
        )
        let date = Date(timeIntervalSince1970: 1_747_655_528)
        let samples = [
            MWLoggedSample(
                date: date,
                tickMs: 12.5,
                value: CorrectedCartesianFloat(x: 1, y: 2, z: 3, accuracy: 2)
            )
        ]
        let snapshot = try await store.saveSession(
            deviceID: UUID(),
            deviceInfo: info,
            sensorKind: CorrectedCartesianFloat.persistenceKind,
            samples: samples,
            label: "Fusion · Corrected Acceleration · 100 Hz"
        )

        let url = try await CSVExporter.exportToTempFile(store: store, snapshot: snapshot)
        let csv = try String(contentsOf: url, encoding: .utf8)

        #expect(csv.contains("epoch,elapsed_ms,x,y,z,accuracy"))
        #expect(csv.contains("12.500,1.000000,2.000000,3.000000,2"))
    }
}
