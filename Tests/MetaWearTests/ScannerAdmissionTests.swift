//
//  ScannerAdmissionTests.swift
//  MetaWearTests
//
//  Covers the scanner's advertisement-admission rule. The original rule was
//  name-prefix only, which silently dropped RENAMED boards from discovery —
//  a board called "bob" never appeared under Nearby on hosts that hadn't
//  remembered it, even though it advertised the MetaWear service UUID.
//

import Foundation
import Testing
@testable import MetaWear

@Suite("Scanner admission")
struct ScannerAdmissionTests {

    private let metaWearService = "326A9000-85CB-9195-D9DD-464CFBBAE75A"
    private let mbientLabMAC = Data([0x6D, 0x62, 0xA4, 0xA6, 0xCE, 0xA4, 0xAA, 0xED])

    @Test
    func admitsDefaultName() {
        #expect(MetaWearScanner.isMetaWearAdvertisement(
            name: "MetaWear", serviceUUIDs: [], manufacturerData: nil
        ))
    }

    @Test
    func admitsRenamedBoardByServiceUUID() {
        // The quirk this rule exists to fix.
        #expect(MetaWearScanner.isMetaWearAdvertisement(
            name: "bob", serviceUUIDs: [metaWearService], manufacturerData: nil
        ))
    }

    @Test
    func serviceUUIDComparisonIsCaseInsensitive() {
        #expect(MetaWearScanner.isMetaWearAdvertisement(
            name: "bob",
            serviceUUIDs: [metaWearService.lowercased()],
            manufacturerData: nil
        ))
    }

    @Test
    func admitsRenamedBoardByMACBroadcast() {
        #expect(MetaWearScanner.isMetaWearAdvertisement(
            name: "bob", serviceUUIDs: [], manufacturerData: mbientLabMAC
        ))
    }

    @Test
    func rejectsForeignPeripherals() {
        let appleMfg = Data([0x4C, 0x00, 0x02, 0x15] + Array(repeating: 0 as UInt8, count: 21))
        #expect(!MetaWearScanner.isMetaWearAdvertisement(
            name: "AirPods Pro",
            serviceUUIDs: ["FE59", "180F"],
            manufacturerData: appleMfg
        ))
        #expect(!MetaWearScanner.isMetaWearAdvertisement(
            name: "", serviceUUIDs: [], manufacturerData: nil
        ))
    }

    @Test
    func rejectsMetaBootMode() {
        // Bootloader boards advertise the Nordic DFU service and the
        // "MetaBoot" name — the normal connect flow can't talk to them.
        #expect(!MetaWearScanner.isMetaWearAdvertisement(
            name: "MetaBoot",
            serviceUUIDs: ["00001530-1212-EFDE-1523-785FEABCD123"],
            manufacturerData: nil
        ))
    }
}
