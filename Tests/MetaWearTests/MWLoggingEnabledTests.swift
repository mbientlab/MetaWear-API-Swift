//
//  MWLoggingEnabledTests.swift
//  MetaWearTests
//
//  Byte contract for the logging-enabled readable — the signal that detects
//  an actively-logging board even when LOG_LENGTH reads 0 (MMS buffers the
//  first flash page in RAM).
//

import Foundation
import Testing
@testable import MetaWear

@Suite("MWLoggingEnabled")
struct MWLoggingEnabledTests {

    @Test
    func readCommandSetsTheReadBit() {
        // [0x0B, 0x81] — Logging ENABLE (0x01) | READ (0x80)
        #expect(MWLoggingEnabled().readCommand == Data([0x0B, 0x81]))
    }

    @Test
    func parsesEnabledAndDisabled() throws {
        #expect(try MWLoggingEnabled().parseSample(from: Data([0x0B, 0x81, 0x01])) == true)
        #expect(try MWLoggingEnabled().parseSample(from: Data([0x0B, 0x81, 0x00])) == false)
    }

    @Test
    func rejectsTruncatedPackets() {
        #expect(throws: MWError.self) {
            _ = try MWLoggingEnabled().parseSample(from: Data([0x0B, 0x81]))
        }
    }
}
