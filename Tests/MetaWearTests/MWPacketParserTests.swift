import Testing
import Foundation
@testable import MetaWear

// MARK: - Primitive parsing

@Suite("Packet Parser — Primitives")
struct PrimitiveParsingTests {

    @Test func parseInt16_positive() {
        let data = Data([0x00, 0x40])             // 0x4000 = 16384
        #expect(MWPacketParser.parseInt16LE(data, offset: 0) == 16384)
    }

    @Test func parseInt16_negative() {
        let data = Data([0xFF, 0xFF])             // 0xFFFF = -1 as Int16
        #expect(MWPacketParser.parseInt16LE(data, offset: 0) == -1)
    }

    @Test func parseInt16_min() {
        let data = Data([0x00, 0x80])             // 0x8000 = -32768
        #expect(MWPacketParser.parseInt16LE(data, offset: 0) == -32768)
    }

    @Test func parseInt16_max() {
        let data = Data([0xFF, 0x7F])             // 0x7FFF = 32767
        #expect(MWPacketParser.parseInt16LE(data, offset: 0) == 32767)
    }

    @Test func parseUInt32_known() {
        let data = Data([0x00, 0x00, 0x01, 0x00]) // 0x00010000 = 65536
        #expect(MWPacketParser.parseUInt32LE(data, offset: 0) == 65536)
    }

    @Test func parseFloat32_one() {
        // IEEE 754 float 1.0 = 0x3F800000, little-endian = [0x00, 0x00, 0x80, 0x3F]
        let data = Data([0x00, 0x00, 0x80, 0x3F])
        #expect(MWPacketParser.parseFloat32LE(data, offset: 0) == 1.0)
    }

    @Test func parseFloat32_negative() {
        // -1.0 = 0xBF800000, LE = [0x00, 0x00, 0x80, 0xBF]
        let data = Data([0x00, 0x00, 0x80, 0xBF])
        #expect(MWPacketParser.parseFloat32LE(data, offset: 0) == -1.0)
    }
}

// MARK: - Accelerometer parsing

@Suite("Packet Parser — Accelerometer")
struct AccelerometerParsingTests {

    // [module, register, x_lo, x_hi, y_lo, y_hi, z_lo, z_hi]
    // x = 0x4000 = 16384 raw → 16384/16384 = 1.0g
    // y = 0x0000 = 0 → 0.0g
    // z = 0x2000 = 8192 → 8192/16384 = 0.5g
    let packet = Data([0x03, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00, 0x20])
    let scale: Float = 16384  // ±2g BMI160

    @Test func parsesXYZ() throws {
        let sample = try MWPacketParser.parseCartesianFloat(packet, scale: scale)
        #expect(sample.x ==  1.0)
        #expect(sample.y ==  0.0)
        #expect(sample.z ==  0.5)
    }

    @Test func parsesNegativeAxis() throws {
        // x = 0xC000 = -16384 raw → -1.0g
        let negPacket = Data([0x03, 0x04, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00])
        let sample = try MWPacketParser.parseCartesianFloat(negPacket, scale: scale)
        #expect(sample.x == -1.0)
    }

    @Test func tooShortThrows() {
        let short = Data([0x03, 0x04, 0x00])
        #expect(throws: (any Error).self) {
            try MWPacketParser.parseCartesianFloat(short, scale: scale)
        }
    }

    @Test func parsesPacked_threesamples() throws {
        // 3 samples: (1g,0,0), (0,1g,0), (0,0,1g)
        var bytes: [UInt8] = [0x03, 0x1C]
        bytes += [0x00, 0x40, 0x00, 0x00, 0x00, 0x00]  // sample 0: x=1g
        bytes += [0x00, 0x00, 0x00, 0x40, 0x00, 0x00]  // sample 1: y=1g
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x40]  // sample 2: z=1g
        let packed = Data(bytes)
        let samples = try MWPacketParser.parsePackedCartesianFloat(packed, scale: scale)
        #expect(samples.count == 3)
        #expect(samples[0].x == 1.0 && samples[0].y == 0.0 && samples[0].z == 0.0)
        #expect(samples[1].x == 0.0 && samples[1].y == 1.0 && samples[1].z == 0.0)
        #expect(samples[2].x == 0.0 && samples[2].y == 0.0 && samples[2].z == 1.0)
    }
}

// MARK: - Sensor fusion parsing

@Suite("Packet Parser — Sensor Fusion")
struct SensorFusionParsingTests {

    @Test func parsesQuaternion() throws {
        // w=1.0, x=0.0, y=0.0, z=0.0 (identity quaternion)
        // Each float32 LE: 1.0 = [0x00,0x00,0x80,0x3F], 0.0 = [0x00,0x00,0x00,0x00]
        var bytes: [UInt8] = [0x19, 0x07]
        bytes += [0x00, 0x00, 0x80, 0x3F]  // w = 1.0
        bytes += [0x00, 0x00, 0x00, 0x00]  // x = 0.0
        bytes += [0x00, 0x00, 0x00, 0x00]  // y = 0.0
        bytes += [0x00, 0x00, 0x00, 0x00]  // z = 0.0
        let q = try MWPacketParser.parseQuaternion(Data(bytes))
        #expect(q.w == 1.0)
        #expect(q.x == 0.0)
        #expect(q.y == 0.0)
        #expect(q.z == 0.0)
    }

    @Test func parsesEulerAngles() throws {
        // heading=90°, pitch=0°, roll=45°, yaw=0°
        func float32LE(_ v: Float) -> [UInt8] {
            var val = v
            return withUnsafeBytes(of: &val) { Array($0) }
        }
        var bytes: [UInt8] = [0x19, 0x08]
        bytes += float32LE(90.0)   // heading
        bytes += float32LE(0.0)    // pitch
        bytes += float32LE(45.0)   // roll
        bytes += float32LE(0.0)    // yaw
        let e = try MWPacketParser.parseEulerAngles(Data(bytes))
        #expect(e.heading == 90.0)
        #expect(e.pitch   == 0.0)
        #expect(e.roll    == 45.0)
        #expect(e.yaw     == 0.0)
    }

    @Test func parsesGravityVector() throws {
        // z = 9.80665 m/s² (pointing down) → z = 1.0g after conversion
        func float32LE(_ v: Float) -> [UInt8] {
            var val = v
            return withUnsafeBytes(of: &val) { Array($0) }
        }
        var bytes: [UInt8] = [0x19, 0x09]
        bytes += float32LE(0.0)
        bytes += float32LE(0.0)
        bytes += float32LE(9.80665)
        let g = try MWPacketParser.parseGravityVector(Data(bytes))
        #expect(g.z.isApproximatelyEqual(to: 1.0, tolerance: 0.0001))
    }
}

// MARK: - Barometer / temperature / battery

@Suite("Packet Parser — Scalar Sensors")
struct ScalarSensorParsingTests {

    @Test func parsesPressure() throws {
        // raw uint32 = 25856 (0x6500) → pressure = 25856/256 = 101.0 Pa
        let bytes: [UInt8] = [0x12, 0x01, 0x00, 0x65, 0x00, 0x00]
        let pa = try MWPacketParser.parsePressure(Data(bytes))
        #expect(pa == 101.0)
    }

    @Test func parsesAltitude() throws {
        // raw int32 = 25600 (0x6400) → altitude = 25600/256 = 100.0m
        let bytes: [UInt8] = [0x12, 0x02, 0x00, 0x64, 0x00, 0x00]
        let m = try MWPacketParser.parseAltitude(Data(bytes))
        #expect(m == 100.0)
    }

    @Test func parsesNegativeAltitude() throws {
        // raw = -256 (0xFFFFFF00 LE = [0x00, 0xFF, 0xFF, 0xFF]) → -256/256 = -1.0m
        let bytes: [UInt8] = [0x12, 0x02, 0x00, 0xFF, 0xFF, 0xFF]
        let m = try MWPacketParser.parseAltitude(Data(bytes))
        #expect(m == -1.0)
    }

    @Test func parsesTemperature() throws {
        // Firmware response: [0x04, 0x81, channel, lo, hi].
        // raw int16 = 200 (0x00C8) → 200/8 = 25.0°C. Channel byte is irrelevant.
        let bytes: [UInt8] = [0x04, 0x81, 0x00, 0xC8, 0x00]
        let c = try MWPacketParser.parseTemperature(Data(bytes))
        #expect(c == 25.0)
    }

    @Test func parsesNegativeTemperature() throws {
        // raw int16 = -80 (0xFFB0) → -80/8 = -10.0°C
        let bytes: [UInt8] = [0x04, 0x81, 0x00, 0xB0, 0xFF]
        let c = try MWPacketParser.parseTemperature(Data(bytes))
        #expect(c == -10.0)
    }

    @Test func parsesBattery() throws {
        // charge = 85%, voltage = 0x0F9C = 3996 mV
        let bytes: [UInt8] = [0x11, 0x91, 0x55, 0x9C, 0x0F]
        let b = try MWPacketParser.parseBatteryState(Data(bytes))
        #expect(b.charge  == 85)
        #expect(b.voltage == 3996)
    }
}

// MARK: - Log entry parsing

@Suite("Packet Parser — Log Entry")
struct LogEntryParsingTests {

    @Test func parsesIdAndResetUID() throws {
        // Byte 0 = 0x63 = 0b01100011 → id = 0x03, resetUID = 0x03
        let bytes: [UInt8] = [0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let (id, resetUID, _, _) = try MWPacketParser.parseLogEntry(Data(bytes))
        #expect(id == 3)
        #expect(resetUID == 3)
    }

    @Test func parsesTick() throws {
        // tick = 0x012345 = 74565 (24-bit LE), bytes [1..3] = [0x45, 0x23, 0x01]
        let bytes: [UInt8] = [0x00, 0x45, 0x23, 0x01, 0x00, 0x00, 0x00, 0x00]
        let (_, _, tick, _) = try MWPacketParser.parseLogEntry(Data(bytes))
        #expect(tick == 74565)
    }

    @Test func msPerTickIsCorrect() {
        let expected = (48.0 / 32768.0) * 1000.0
        #expect(abs(MWPacketParser.msPerTick - expected) < 0.000001)
    }
}

// MARK: - Float comparison helper

private extension Float {
    func isApproximatelyEqual(to other: Float, tolerance: Float) -> Bool {
        abs(self - other) <= tolerance
    }
}
