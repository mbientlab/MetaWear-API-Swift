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

    /// With several boards, two same-named boards can finish downloads in
    /// the same second — the discriminator keeps the temp filenames from
    /// silently overwriting each other.
    @Test func discriminatorMakesSameSecondFilenamesDistinct() {
        let date = Date(timeIntervalSince1970: 1747655528)
        let a = ExportFilename.make(deviceName: "MetaWear", sensorKind: "accel",
                                    date: date, discriminator: "3F2A")
        let b = ExportFilename.make(deviceName: "MetaWear", sensorKind: "accel",
                                    date: date, discriminator: "9C01")
        #expect(a != b)
        #expect(a.hasSuffix("-3F2A.csv"))
        // No discriminator → legacy shape, unchanged.
        let legacy = ExportFilename.make(deviceName: "MetaWear", sensorKind: "accel", date: date)
        #expect(!legacy.contains("--"))
    }

    @Test func unsafeCharactersAreStripped() {
        let name = ExportFilename.make(deviceName: "Lab/Bench #3", sensorKind: "cartesian")
        #expect(!name.contains("/"))
        #expect(!name.contains("#"))
        #expect(!name.contains(" "))
    }
}
