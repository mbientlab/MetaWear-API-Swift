import Testing
import Foundation
@testable import MetaWearApp

@Suite("ExportFilename")
struct ExportFilenameTests {

    @Test func filenameUsesDashesOnly() {
        let date = Date(timeIntervalSince1970: 1747655528)
        let name = ExportFilename.make(deviceName: "MetaWear R", sensorKind: "accelerometer", date: date)
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".csv"))
        #expect(name.contains("MetaWearR"))
        #expect(name.contains("accelerometer"))
    }

    @Test func emptyDeviceNameDefaults() {
        let name = ExportFilename.make(deviceName: "", sensorKind: "gyroscope")
        #expect(name.hasPrefix("MetaWear-gyroscope-"))
    }

    @Test func unsafeCharactersAreStripped() {
        let name = ExportFilename.make(deviceName: "Lab/Bench #3", sensorKind: "cartesian")
        #expect(!name.contains("/"))
        #expect(!name.contains("#"))
        #expect(!name.contains(" "))
    }
}
