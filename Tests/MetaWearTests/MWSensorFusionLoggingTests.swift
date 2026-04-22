import Testing
import Foundation
@testable import MetaWear

// MARK: - Sensor fusion MWLoggable conformance

@Suite("Sensor Fusion Logging")
struct SensorFusionLoggingTests {

    // MARK: Logger keys

    @Test func quaternion_loggerKey() {
        #expect(MWSensorFusionQuaternion().loggerKey == "quaternion")
    }

    @Test func euler_loggerKey() {
        #expect(MWSensorFusionEuler().loggerKey == "euler-angles")
    }

    @Test func gravity_loggerKey() {
        #expect(MWSensorFusionGravity().loggerKey == "gravity")
    }

    @Test func linearAcc_loggerKey() {
        #expect(MWSensorFusionLinearAcceleration().loggerKey == "linear-acceleration")
    }

    // MARK: Chunk layouts — Quaternion (4 × float32 = 16 bytes → 4 chunks)

    @Test func quaternion_chunkCount() {
        #expect(MWSensorFusionQuaternion().logDataChunks.count == 4)
    }

    @Test func quaternion_chunkOffsets() {
        let offsets = MWSensorFusionQuaternion().logDataChunks.map { $0.offset }
        #expect(offsets == [0, 4, 8, 12])
    }

    @Test func quaternion_chunkLengths_allFour() {
        let lengths = MWSensorFusionQuaternion().logDataChunks.map { $0.length }
        #expect(lengths.allSatisfy { $0 == 4 })
    }

    // MARK: Chunk layouts — EulerAngles (4 × float32 = 16 bytes → 4 chunks)

    @Test func euler_chunkCount() {
        #expect(MWSensorFusionEuler().logDataChunks.count == 4)
    }

    @Test func euler_chunkOffsets() {
        let offsets = MWSensorFusionEuler().logDataChunks.map { $0.offset }
        #expect(offsets == [0, 4, 8, 12])
    }

    @Test func euler_chunkLengths_allFour() {
        let lengths = MWSensorFusionEuler().logDataChunks.map { $0.length }
        #expect(lengths.allSatisfy { $0 == 4 })
    }

    // MARK: Chunk layouts — Gravity / LinearAcc (3 × float32 = 12 bytes → 3 chunks)

    @Test func gravity_chunkCount() {
        #expect(MWSensorFusionGravity().logDataChunks.count == 3)
    }

    @Test func gravity_chunkOffsets() {
        let offsets = MWSensorFusionGravity().logDataChunks.map { $0.offset }
        #expect(offsets == [0, 4, 8])
    }

    @Test func gravity_chunkLengths_allFour() {
        let lengths = MWSensorFusionGravity().logDataChunks.map { $0.length }
        #expect(lengths.allSatisfy { $0 == 4 })
    }

    @Test func linearAcc_chunkCount() {
        #expect(MWSensorFusionLinearAcceleration().logDataChunks.count == 3)
    }

    @Test func linearAcc_chunkOffsets() {
        let offsets = MWSensorFusionLinearAcceleration().logDataChunks.map { $0.offset }
        #expect(offsets == [0, 4, 8])
    }

    // MARK: parseLogSample — Quaternion

    @Test func quaternion_parseLogSample_unitQuaternion() throws {
        // Build 16 bytes: w=1.0, x=0.0, y=0.0, z=0.0 as little-endian float32s
        let data = encodedFloats([1.0, 0.0, 0.0, 0.0])
        let q = try MWSensorFusionQuaternion().parseLogSample(from: data)
        #expect(abs(q.w - 1.0) < 0.0001)
        #expect(abs(q.x) < 0.0001)
        #expect(abs(q.y) < 0.0001)
        #expect(abs(q.z) < 0.0001)
    }

    @Test func quaternion_parseLogSample_arbitraryValues() throws {
        let data = encodedFloats([0.5, 0.5, 0.5, 0.5])
        let q = try MWSensorFusionQuaternion().parseLogSample(from: data)
        #expect(abs(q.w - 0.5) < 0.0001)
        #expect(abs(q.x - 0.5) < 0.0001)
        #expect(abs(q.y - 0.5) < 0.0001)
        #expect(abs(q.z - 0.5) < 0.0001)
    }

    // MARK: parseLogSample — EulerAngles

    @Test func euler_parseLogSample() throws {
        // heading=90, pitch=-45, roll=0, yaw=180
        let data = encodedFloats([90.0, -45.0, 0.0, 180.0])
        let e = try MWSensorFusionEuler().parseLogSample(from: data)
        #expect(abs(e.heading - 90.0) < 0.001)
        #expect(abs(e.pitch - (-45.0)) < 0.001)
        #expect(abs(e.roll) < 0.001)
        #expect(abs(e.yaw - 180.0) < 0.001)
    }

    // MARK: parseLogSample — Gravity (m/s² → g via /9.80665)

    @Test func gravity_parseLogSample_pointsDown() throws {
        // 1g downward: z = 9.80665 m/s² → after /9.80665 = 1.0 g
        let data = encodedFloats([0.0, 0.0, 9.80665])
        let g = try MWSensorFusionGravity().parseLogSample(from: data)
        #expect(abs(g.x) < 0.0001)
        #expect(abs(g.y) < 0.0001)
        #expect(abs(g.z - 1.0) < 0.0001)
    }
}

// MARK: - Helpers

/// Encode an array of Float values as contiguous little-endian float32 bytes.
private func encodedFloats(_ values: [Float]) -> Data {
    var data = Data()
    for f in values {
        let bits = f.bitPattern
        data.append(contentsOf: [
            UInt8(bits & 0xFF),
            UInt8((bits >> 8)  & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 24) & 0xFF)
        ])
    }
    return data
}
