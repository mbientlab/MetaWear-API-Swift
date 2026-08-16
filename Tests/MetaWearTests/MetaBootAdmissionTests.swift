//
//  MetaBootAdmissionTests.swift
//  MetaWearTests
//
//  Mirror of `ScannerAdmissionTests` for the MetaBoot (bootloader) admission
//  rule. The two predicates are disjoint by design — an advertisement matches
//  one, the other, or neither, never both — so the two suites together cover
//  the scanner's routing gate.
//

import Foundation
import Testing
@testable import MetaWear

@Suite("MetaBoot admission")
struct MetaBootAdmissionTests {

    private let nordicDFUService = "00001530-1212-EFDE-1523-785FEABCD123"
    private let metaWearService = "326A9000-85CB-9195-D9DD-464CFBBAE75A"

    // MARK: - Admission signals

    @Test
    func admitsDefaultName() {
        // MetaBoot's canonical local name.
        #expect(MetaWearScanner.isMetaBootAdvertisement(
            name: "MetaBoot", serviceUUIDs: []
        ))
    }

    @Test
    func admitsByNordicDFUServiceUUID() {
        // A MetaBoot with a customised name should still be detectable via
        // the Nordic DFU service in its advertised service list.
        #expect(MetaWearScanner.isMetaBootAdvertisement(
            name: "bob", serviceUUIDs: [nordicDFUService]
        ))
    }

    @Test
    func serviceUUIDComparisonIsCaseInsensitive() {
        #expect(MetaWearScanner.isMetaBootAdvertisement(
            name: "bob", serviceUUIDs: [nordicDFUService.lowercased()]
        ))
    }

    // MARK: - Rejection signals

    @Test
    func rejectsApplicationModeBoard() {
        // The default MetaWear ad — service UUID matches the MetaWear
        // command service, name prefix "MetaWear". Must NOT surface as a
        // MetaBoot device or the scanner's routing gate is broken.
        #expect(!MetaWearScanner.isMetaBootAdvertisement(
            name: "MetaWear", serviceUUIDs: [metaWearService]
        ))
    }

    @Test
    func rejectsRenamedApplicationModeBoard() {
        // Same as above but the operator renamed the board to something
        // that could be mistaken for a bootloader on a lazy substring match.
        // The predicate demands EXACT name equality, not `hasPrefix`.
        #expect(!MetaWearScanner.isMetaBootAdvertisement(
            name: "MetaBoot-clone", serviceUUIDs: [metaWearService]
        ))
    }

    @Test
    func rejectsForeignPeripherals() {
        #expect(!MetaWearScanner.isMetaBootAdvertisement(
            name: "AirPods Pro", serviceUUIDs: ["FE59", "180F"]
        ))
        #expect(!MetaWearScanner.isMetaBootAdvertisement(
            name: "", serviceUUIDs: []
        ))
    }

    // MARK: - Disjoint from MetaWear admission

    @Test
    func mutuallyExclusiveWithMetaWearAdmission() {
        // Every advertisement matches AT MOST one predicate. This is the
        // invariant the scanner's routing gate depends on — if both were
        // true a device would appear in both discovery buckets.
        let candidates: [(name: String, services: [String], mfg: Data?)] = [
            ("MetaWear",  [metaWearService], nil),
            ("bob",       [metaWearService], nil),
            ("MetaBoot",  [], nil),
            ("bob",       [nordicDFUService], nil),
            ("",          [], nil),
            ("AirPods",   ["FE59"], nil),
        ]
        for candidate in candidates {
            let asMetaWear = MetaWearScanner.isMetaWearAdvertisement(
                name: candidate.name,
                serviceUUIDs: candidate.services,
                manufacturerData: candidate.mfg
            )
            let asMetaBoot = MetaWearScanner.isMetaBootAdvertisement(
                name: candidate.name,
                serviceUUIDs: candidate.services
            )
            #expect(!(asMetaWear && asMetaBoot),
                    "Advertisement '\(candidate.name)' \(candidate.services) matched BOTH admission predicates — the routing gate would double-vend it.")
        }
    }
}
