import Testing
import Foundation
import MetaWearPersistence
@testable import MetaWearApp

/// History sections must be keyed by board IDENTITY (DIS serial), never by
/// display name — stock boards all advertise "MetaWear", and legacy records
/// carry no name at all. Adversarial review of the attribution prebake
/// caught the name-keyed version merging distinct boards and splitting an
/// upgrading user's history in two.
@MainActor
struct SessionHistoryGroupingTests {

    private func snap(
        serial: String, name: String?, start: TimeInterval,
        deviceID: UUID = UUID()
    ) -> MWSessionSnapshot {
        MWSessionSnapshot(
            deviceID: deviceID,
            sensorKind: "cartesian",
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start + 60),
            sampleCount: 10,
            deviceSerial: serial,
            deviceName: name
        )
    }

    @Test func twoDefaultNamedBoardsGetSeparateDisambiguatedSections() {
        let sections = SessionHistoryGrouping.sections(from: [
            snap(serial: "0123FF", name: "MetaWear", start: 200),
            snap(serial: "045A2C", name: "MetaWear", start: 100),
        ])
        #expect(sections.count == 2)
        #expect(sections[0].title == "MetaWear · 0123FF")
        #expect(sections[1].title == "MetaWear · 045A2C")
    }

    @Test func legacyAndNewRecordsOfOneBoardShareASection() {
        // Same board: pre-migration record (nil name) + new stamped record.
        let sections = SessionHistoryGrouping.sections(from: [
            snap(serial: "0123FF", name: "bob", start: 200),
            snap(serial: "0123FF", name: nil, start: 100),
        ])
        #expect(sections.count == 1)
        #expect(sections[0].title == "bob")
        #expect(sections[0].sessions.count == 2)
    }

    @Test func uniqueRenamedBoardKeepsPlainTitle() {
        let sections = SessionHistoryGrouping.sections(from: [
            snap(serial: "0123FF", name: "bob", start: 200),
            snap(serial: "045A2C", name: "MetaWear", start: 100),
        ])
        #expect(sections.map(\.title) == ["bob", "MetaWear"])
    }

    @Test func renameWinsForTheSectionTitle() {
        // Newest-first input (store order): the freshest stamped name titles
        // the section even though older sessions carry the old name.
        let sections = SessionHistoryGrouping.sections(from: [
            snap(serial: "0123FF", name: "bob", start: 300),
            snap(serial: "0123FF", name: "MetaWear", start: 100),
        ])
        #expect(sections.count == 1)
        #expect(sections[0].title == "bob")
    }

    @Test func namelessBoardFallsBackToSerialThenUnknown() {
        let id = UUID()
        let sections = SessionHistoryGrouping.sections(from: [
            snap(serial: "0123FF", name: nil, start: 200),
            snap(serial: "", name: nil, start: 100, deviceID: id),
        ])
        #expect(sections[0].title == "0123FF")
        #expect(sections[1].title == "Unknown board")
        #expect(sections[1].id == id.uuidString)
    }

    @Test func sectionsOrderNewestFirst() {
        let sections = SessionHistoryGrouping.sections(from: [
            snap(serial: "AAAA01", name: "old board", start: 100),
            snap(serial: "BBBB02", name: "new board", start: 900),
        ])
        #expect(sections.map(\.title) == ["new board", "old board"])
    }
}
