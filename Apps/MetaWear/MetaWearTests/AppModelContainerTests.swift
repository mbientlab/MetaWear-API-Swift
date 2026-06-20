import Foundation
import SwiftData
import Testing
import MetaWearPersistence
@testable import MetaWearApp

@Suite("App model containers")
@MainActor
struct AppModelContainerTests {

    @Test func separatesRememberedDevicesFromSessionStorage() throws {
        let containers = try AppModelContainer.makeShared(inMemory: true)

        #expect(containers.cloud !== containers.local)

        let rememberedContext = containers.cloud.mainContext
        let localContext = containers.local.mainContext

        let deviceID = UUID()
        let remembered = RememberedDevice(
            peripheralUUID: deviceID,
            name: "MetaWear Test",
            serialNumber: "SERIAL-1",
            firmwareRevision: "1.0.0",
            modelNumber: "MMS"
        )
        rememberedContext.insert(remembered)
        try rememberedContext.save()

        let rememberedDevices = try rememberedContext.fetch(FetchDescriptor<RememberedDevice>())
        #expect(rememberedDevices.map(\.peripheralUUID) == [deviceID])

        let sessionID = UUID()
        let session = MWSessionRecord(
            id: sessionID,
            deviceID: deviceID,
            sensorKind: "float",
            startDate: Date(timeIntervalSince1970: 1),
            endDate: Date(timeIntervalSince1970: 2),
            deviceSerial: "SERIAL-1",
            deviceModel: "MMS",
            deviceFirmware: "1.0.0",
            label: "Temperature"
        )
        localContext.insert(session)
        try localContext.save()

        let sessions = try localContext.fetch(FetchDescriptor<MWSessionRecord>())
        #expect(sessions.map(\.id) == [sessionID])
    }
}
