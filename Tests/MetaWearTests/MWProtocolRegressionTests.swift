import Testing
import Foundation
@testable import MetaWear

// MARK: - Math processor firmware op codes
//
// Regression guard for a real bug: an earlier draft of `Math.Operation` used a
// 0-indexed table from a buggy protocol document, which made `.add` a no-op
// and `.subtract` perform addition on the board. The firmware op codes
// (verified against `MblMwMathOperation` in MetaWear-SDK-Cpp, written to the
// wire verbatim by `MathConfig.operation = op`) are pinned here one by one so
// any future renumbering fails loudly.

@Suite("Math processor — firmware op codes")
struct MathOperationWireValueTests {

    private static let firmwareOpCodes: [(MWDataProcessor.Math.Operation, UInt8)] = [
        (.add,      1),
        (.multiply, 2),
        (.divide,   3),
        (.modulo,   4),
        (.exponent, 5),
        (.sqrt,     6),
        (.lshift,   7),
        (.rshift,   8),
        (.subtract, 9),
        (.abs,      10),
        (.constant, 11),
    ]

    @Test(arguments: firmwareOpCodes)
    func opCode_matchesFirmware(op: MWDataProcessor.Math.Operation, expected: UInt8) {
        #expect(op.rawValue == expected)
    }

    @Test func opCode_table_isExhaustive() {
        // No phantom operations: the firmware defines exactly these 11.
        // Negate/floor/ceil/round do not exist on the wire.
        #expect(MWDataProcessor.Math.Operation.allCases.count == Self.firmwareOpCodes.count)
    }

    @Test func configBytes_putOpCodeAtByte1() {
        // subtract is the case the old table got most wrong (1 → firmware add).
        let config = MWDataProcessor.Math(operation: .subtract, rhs: 5, signed: true)
        let bytes = config.configBytes(inputLength: 4, inputChannels: 1, inputSigned: true)
        // [byte0, op, rhs(4 LE), n_channels]
        #expect(bytes.count == 7)
        #expect(bytes[1] == 9)
        #expect(Array(bytes[2...5]) == [0x05, 0x00, 0x00, 0x00])
    }
}

// MARK: - LED repeat count encoding
//
// The firmware treats a raw repeat count of 0 as undefined behaviour; the C++
// SDK's guidance is "use 0xFF, not 0". The Swift encoder must never emit 0.

@Suite("LED pattern — repeat count encoding")
struct LEDRepeatCountTests {

    @Test func defaultPattern_repeatsIndefinitely() {
        #expect(MWLEDPattern().repeatCount == .max)
    }

    @Test func explicitZero_isEncodedAsIndefinite() {
        let pattern = MWLEDPattern(repeatCount: 0)
        let cmd = MWLED.SetPattern(color: .green, pattern: pattern).commandData
        // [0x02, 0x03, channel, mode, hi, lo, rise(2), high(2), fall(2),
        //  pulse(2), delay(2), repeat] — repeat is the final byte.
        #expect(cmd.count == 17)
        #expect(cmd.last == 0xFF)
    }

    @Test func finiteCount_isPreserved() {
        let pattern = MWLEDPattern(repeatCount: 3)
        let cmd = MWLED.SetPattern(color: .blue, pattern: pattern).commandData
        #expect(cmd.last == 3)
    }
}

// MARK: - Log reassembly at high ODR (same-tick samples)
//
// One tick is ≈1.465 ms, so at 800/1600 Hz two distinct samples can land on
// the same tick. The decoder pairs chunk entries by per-logger-ID arrival
// order (like the C++ SDK) — an earlier draft grouped by identical
// (resetUID, tick), which collapsed same-tick samples into one and dropped
// data. Fixture: two 2-chunk samples, all four entries at tick=1.

@Suite("Log decode — same-tick sample pairing")
struct LogSameTickDecodeTests {

    private func device() -> MetaWearDevice {
        MetaWearDevice(identifier: UUID(), transport: MockBLETransport())
    }

    @Test func twoSamplesSharingATick_bothDecode() async throws {
        let entries: [RawLogEntry] = [
            // Sample 1: chunk id 0 (data 0x00004000), chunk id 1 (data 0x00002000)
            try RawLogEntry(entryBytes: Data([0x00, 0x01, 0x00, 0x00, 0x00,  0x00, 0x40, 0x00, 0x00])),
            try RawLogEntry(entryBytes: Data([0x01, 0x01, 0x00, 0x00, 0x00,  0x00, 0x20, 0x00, 0x00])),
            // Sample 2: same tick, different data (0x00008000 / 0x00001000)
            try RawLogEntry(entryBytes: Data([0x00, 0x01, 0x00, 0x00, 0x00,  0x00, 0x80, 0x00, 0x00])),
            try RawLogEntry(entryBytes: Data([0x01, 0x01, 0x00, 0x00, 0x00,  0x00, 0x10, 0x00, 0x00])),
        ]
        let chunks: [(id: UInt8, byteCount: Int)] = [(id: 0, byteCount: 4), (id: 1, byteCount: 2)]

        let samples = try await device()._decodeEntries(entries, chunks: chunks) { $0 }

        #expect(samples.count == 2)
        let payloads = samples.map { Array($0.value) }
        #expect(payloads.contains([0x00, 0x40, 0x00, 0x00, 0x00, 0x20]))
        #expect(payloads.contains([0x00, 0x80, 0x00, 0x00, 0x00, 0x10]))
    }

    @Test func chunksPair_byArrivalOrder_notInterleaved() async throws {
        // Chunk entries arrive grouped per sample; pairing index i of queue 0
        // with index i of queue 1 must not mix sample 1's first chunk with
        // sample 2's second chunk.
        let entries: [RawLogEntry] = [
            try RawLogEntry(entryBytes: Data([0x00, 0x0A, 0x00, 0x00, 0x00,  0x11, 0x11, 0x11, 0x11])),
            try RawLogEntry(entryBytes: Data([0x01, 0x0A, 0x00, 0x00, 0x00,  0x22, 0x22, 0x22, 0x22])),
            try RawLogEntry(entryBytes: Data([0x00, 0x0B, 0x00, 0x00, 0x00,  0x33, 0x33, 0x33, 0x33])),
            try RawLogEntry(entryBytes: Data([0x01, 0x0B, 0x00, 0x00, 0x00,  0x44, 0x44, 0x44, 0x44])),
        ]
        let chunks: [(id: UInt8, byteCount: Int)] = [(id: 0, byteCount: 4), (id: 1, byteCount: 2)]

        let samples = try await device()._decodeEntries(entries, chunks: chunks) { $0 }

        try #require(samples.count == 2)
        #expect(Array(samples[0].value) == [0x11, 0x11, 0x11, 0x11, 0x22, 0x22])
        #expect(Array(samples[1].value) == [0x33, 0x33, 0x33, 0x33, 0x44, 0x44])
    }

    @Test func incompleteTrailingSample_isDropped() async throws {
        // Last sample's second chunk was cut off by the end of the download.
        let entries: [RawLogEntry] = [
            try RawLogEntry(entryBytes: Data([0x00, 0x01, 0x00, 0x00, 0x00,  0x00, 0x40, 0x00, 0x00])),
            try RawLogEntry(entryBytes: Data([0x01, 0x01, 0x00, 0x00, 0x00,  0x00, 0x20, 0x00, 0x00])),
            try RawLogEntry(entryBytes: Data([0x00, 0x02, 0x00, 0x00, 0x00,  0x00, 0x80, 0x00, 0x00])),
        ]
        let chunks: [(id: UInt8, byteCount: Int)] = [(id: 0, byteCount: 4), (id: 1, byteCount: 2)]

        let samples = try await device()._decodeEntries(entries, chunks: chunks) { $0 }
        #expect(samples.count == 1)
    }
}

// MARK: - MAC address response lengths
//
// The payload is 6 bytes on older firmware and 7 bytes (leading address-type
// byte) on current firmware. C++ `convert_to_mac_address` handles both via
// `offset = len == 7 ? 1 : 0`; the Swift parser must too.

@Suite("Packet Parser — MAC address")
struct MacAddressParsingTests {

    @Test func sevenBytePayload_currentFirmware() throws {
        // mbientlab python reference vector (test_settings.py::test_mac_address)
        let packet = Data([0x11, 0x8B, 0x01, 0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8])
        #expect(try MWPacketParser.parseMacAddress(packet) == "E8:C9:8F:52:7B:07")
    }

    @Test func sixBytePayload_olderFirmware() throws {
        let packet = Data([0x11, 0x8B, 0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8])
        #expect(try MWPacketParser.parseMacAddress(packet) == "E8:C9:8F:52:7B:07")
    }

    @Test func tooShort_throws() {
        #expect(throws: MWError.self) {
            try MWPacketParser.parseMacAddress(Data([0x11, 0x8B, 0x01, 0x02]))
        }
    }
}
