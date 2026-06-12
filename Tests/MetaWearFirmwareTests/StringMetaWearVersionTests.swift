//
//  StringMetaWearVersionTests.swift
//  MetaWearFirmwareTests
//
//  Coverage for the dotted-numeric-with-padding version comparison used to
//  sort firmware revisions and gate `min-ios-version`.
//
//  The helpers are file-private to MetaWearFirmware, so this file is
//  compiled into the firmware test target alongside `@testable import`.
//

import Testing
@testable import MetaWearFirmware

@Suite("String — MetaWear version comparison")
struct StringMetaWearVersionTests {

    // MARK: - Equal-length numeric compare

    @Test
    func equalVersions_compareEqual() {
        #expect("1.5.0".isMetaWearVersion(equalTo: "1.5.0"))
        #expect("0.0.0".isMetaWearVersion(equalTo: "0.0.0"))
        #expect("10.20.30".isMetaWearVersion(equalTo: "10.20.30"))
    }

    @Test
    func differentVersions_orderedCorrectly() {
        #expect("1.5.0".isMetaWearVersion(lessThan: "1.5.1"))
        #expect("1.5.1".isMetaWearVersion(greaterThan: "1.5.0"))
        #expect("1.4.99".isMetaWearVersion(lessThan: "1.5.0"))
    }

    @Test
    func numericComponents_avoidLexicalSort() {
        // Lexical sort would put "10" < "9" — numeric must put 9 < 10.
        #expect("9.0.0".isMetaWearVersion(lessThan: "10.0.0"))
        #expect("1.9.0".isMetaWearVersion(lessThan: "1.10.0"))
        #expect("1.0.9".isMetaWearVersion(lessThan: "1.0.10"))
    }

    // MARK: - Different-length comparisons (zero-padding)

    @Test
    func shortFormPadsToLong_compareEqual() {
        // "1.5" should compare equal to "1.5.0" because the comparator
        // right-pads the shorter side with zeros.
        #expect("1.5".isMetaWearVersion(equalTo: "1.5.0"))
        #expect("1.5.0".isMetaWearVersion(equalTo: "1.5"))
        #expect("1".isMetaWearVersion(equalTo: "1.0.0"))
    }

    @Test
    func shortVsLong_orderingPreserved() {
        #expect("1.5".isMetaWearVersion(lessThan: "1.5.1"))
        #expect("1.5.1".isMetaWearVersion(greaterThan: "1.5"))
        // Trailing zeros really are zeros — "2" < "2.0.1".
        #expect("2".isMetaWearVersion(lessThan: "2.0.1"))
    }

    // MARK: - Inclusive comparisons

    @Test
    func greaterThanOrEqual_handlesEdges() {
        #expect("1.5.0".isMetaWearVersion(greaterThanOrEqualTo: "1.5.0"))
        #expect("1.5.1".isMetaWearVersion(greaterThanOrEqualTo: "1.5.0"))
        #expect(!"1.4.99".isMetaWearVersion(greaterThanOrEqualTo: "1.5.0"))
    }

    @Test
    func lessThanOrEqual_handlesEdges() {
        #expect("1.5.0".isMetaWearVersion(lessThanOrEqualTo: "1.5.0"))
        #expect("1.4.99".isMetaWearVersion(lessThanOrEqualTo: "1.5.0"))
        #expect(!"1.5.1".isMetaWearVersion(lessThanOrEqualTo: "1.5.0"))
    }

    // MARK: - Real-world MetaWear strings

    @Test
    func realWorldFirmwareStrings_orderedCorrectly() {
        // From actual catalog history. All vanilla MetaMotion R builds.
        let history = ["1.0.0", "1.2.5", "1.3.4", "1.4.3", "1.5.0", "1.7.3"]
        for (a, b) in zip(history, history.dropFirst()) {
            #expect(a.isMetaWearVersion(lessThan: b),
                    "\(a) should sort before \(b)")
        }
    }

    @Test
    func sdkVersionGate_realWorldExample() {
        // Catalog entries carry `min-ios-version` like "3.0.0" or "3.2.0".
        // SDK 3.2.0 should accept both; SDK 2.9.0 should accept neither.
        #expect("3.2.0".isMetaWearVersion(greaterThanOrEqualTo: "3.0.0"))
        #expect("3.2.0".isMetaWearVersion(greaterThanOrEqualTo: "3.2.0"))
        #expect(!"2.9.0".isMetaWearVersion(greaterThanOrEqualTo: "3.0.0"))
    }
}
