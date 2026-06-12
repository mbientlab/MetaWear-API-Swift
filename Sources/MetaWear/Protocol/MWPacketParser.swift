import Foundation

/// Static helpers for parsing raw MetaWear notification bytes into Swift values.
/// All multi-byte values in the MetaWear protocol are little-endian.
enum MWPacketParser {

    // MARK: - Primitives

    static func parseInt16LE(_ data: Data, offset: Int) -> Int16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return Int16(bitPattern: lo | (hi << 8))
    }

    static func parseUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return lo | (hi << 8)
    }

    static func parseUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    static func parseInt32LE(_ data: Data, offset: Int) -> Int32 {
        Int32(bitPattern: parseUInt32LE(data, offset: offset))
    }

    static func parseFloat32LE(_ data: Data, offset: Int) -> Float {
        let bits = parseUInt32LE(data, offset: offset)
        return Float(bitPattern: bits)
    }

    // MARK: - CartesianFloat from scaled int16 (accelerometer, gyroscope, magnetometer)
    // Packet layout: [module, register, x_lo, x_hi, y_lo, y_hi, z_lo, z_hi]

    static func parseCartesianFloat(_ packet: Data, scale: Float) throws -> CartesianFloat {
        guard packet.count >= 8 else {
            throw MWError.operationFailed("Packet too short for CartesianFloat: \(packet.count) bytes")
        }
        let x = Float(parseInt16LE(packet, offset: 2)) / scale
        let y = Float(parseInt16LE(packet, offset: 4)) / scale
        let z = Float(parseInt16LE(packet, offset: 6)) / scale
        return CartesianFloat(x: x, y: y, z: z)
    }

    /// Unpack 3 consecutive XYZ samples from a packed-data notification.
    /// Packed layout: [module, register, x0_lo, x0_hi, y0_lo, y0_hi, z0_lo, z0_hi, x1..., x2...]
    static func parsePackedCartesianFloat(_ packet: Data, scale: Float) throws -> [CartesianFloat] {
        guard packet.count >= 20 else {
            throw MWError.operationFailed("Packed packet too short: \(packet.count) bytes")
        }
        return (0..<3).map { i in
            let offset = 2 + i * 6
            return CartesianFloat(
                x: Float(parseInt16LE(packet, offset: offset))     / scale,
                y: Float(parseInt16LE(packet, offset: offset + 2)) / scale,
                z: Float(parseInt16LE(packet, offset: offset + 4)) / scale
            )
        }
    }

    // MARK: - CartesianFloat from float32 (sensor fusion corrected outputs)
    // Packet layout: [module, register, x_f32, y_f32, z_f32, accuracy]

    static func parseCorrectedCartesianFloat(_ packet: Data, scale: Float = 1.0) throws -> CorrectedCartesianFloat {
        guard packet.count >= 15 else {
            throw MWError.operationFailed("Packet too short for CorrectedCartesianFloat: \(packet.count) bytes")
        }
        return CorrectedCartesianFloat(
            x: parseFloat32LE(packet, offset: 2)  / scale,
            y: parseFloat32LE(packet, offset: 6)  / scale,
            z: parseFloat32LE(packet, offset: 10) / scale,
            accuracy: packet[14]
        )
    }

    // MARK: - Quaternion (sensor fusion)
    // Packet layout: [module, register, w_f32, x_f32, y_f32, z_f32]

    static func parseQuaternion(_ packet: Data) throws -> Quaternion {
        guard packet.count >= 18 else {
            throw MWError.operationFailed("Packet too short for Quaternion: \(packet.count) bytes")
        }
        return Quaternion(
            w: parseFloat32LE(packet, offset: 2),
            x: parseFloat32LE(packet, offset: 6),
            y: parseFloat32LE(packet, offset: 10),
            z: parseFloat32LE(packet, offset: 14)
        )
    }

    // MARK: - Euler angles (sensor fusion)
    // Packet layout: [module, register, heading_f32, pitch_f32, roll_f32, yaw_f32]

    static func parseEulerAngles(_ packet: Data) throws -> EulerAngles {
        guard packet.count >= 18 else {
            throw MWError.operationFailed("Packet too short for EulerAngles: \(packet.count) bytes")
        }
        return EulerAngles(
            heading: parseFloat32LE(packet, offset: 2),
            pitch:   parseFloat32LE(packet, offset: 6),
            roll:    parseFloat32LE(packet, offset: 10),
            yaw:     parseFloat32LE(packet, offset: 14)
        )
    }

    // MARK: - Gravity / linear acceleration (sensor fusion)
    // Packet layout: [module, register, x_f32, y_f32, z_f32] — convert m/s² → g

    static func parseGravityVector(_ packet: Data) throws -> CartesianFloat {
        guard packet.count >= 14 else {
            throw MWError.operationFailed("Packet too short for gravity vector: \(packet.count) bytes")
        }
        let mssToG: Float = 9.80665
        return CartesianFloat(
            x: parseFloat32LE(packet, offset: 2)  / mssToG,
            y: parseFloat32LE(packet, offset: 6)  / mssToG,
            z: parseFloat32LE(packet, offset: 10) / mssToG
        )
    }

    // MARK: - Pressure / altitude (barometer)

    static func parsePressure(_ packet: Data) throws -> Float {
        guard packet.count >= 6 else {
            throw MWError.operationFailed("Packet too short for pressure: \(packet.count) bytes")
        }
        let raw = parseUInt32LE(packet, offset: 2)
        return Float(raw) / 256.0
    }

    static func parseAltitude(_ packet: Data) throws -> Float {
        guard packet.count >= 6 else {
            throw MWError.operationFailed("Packet too short for altitude: \(packet.count) bytes")
        }
        let raw = parseInt32LE(packet, offset: 2)
        return Float(raw) / 256.0
    }

    // MARK: - Temperature
    //
    // Multi-channel temperature response shape per C++ `multichanneltemperature.cpp`:
    //   [module=0x04, register=0x81, channel, lo, hi]
    // The channel ID sits at offset 2, and the signed 16-bit Celsius-value /
    // 8 lives at offset 3.

    static func parseTemperature(_ packet: Data) throws -> Float {
        guard packet.count >= 5 else {
            throw MWError.operationFailed("Packet too short for temperature: \(packet.count) bytes")
        }
        let raw = parseInt16LE(packet, offset: 3)
        return Float(raw) / 8.0
    }

    // MARK: - Ambient light (LTR329)
    //
    // Response shape per C++ `ambientlight_ltr329.cpp` (DataInterpreter::UINT32
    // at offset 0, 4 bytes):
    //   [module=0x14, register=0x03, lo, mlo, mhi, hi]
    // The UInt32 is raw milli-lux (lux × 1000), so divide by 1000 for float lux.
    //
    // Python reference (`test_ambientlight_ltr329.py::test_get_illuminance_data`):
    //   b'\x14\x03\xed\x92\xb0\x00' → 11571949 raw → 11571.949 lux.

    static func parseIlluminanceRaw(_ packet: Data) throws -> UInt32 {
        guard packet.count >= 6 else {
            throw MWError.operationFailed("Packet too short for illuminance: \(packet.count) bytes")
        }
        return parseUInt32LE(packet, offset: 2)
    }

    static func parseIlluminance(_ packet: Data) throws -> Float {
        let raw = try parseIlluminanceRaw(packet)
        return Float(raw) / 1000.0
    }

    // MARK: - Humidity (BME280)
    //
    // Response shape per C++ `humidity_bme280.cpp`:
    //   [module=0x16, register=0x81, raw_lo, raw_mid_lo, raw_mid_hi, raw_hi]
    // The raw UInt32 LE at offset 2 divided by 1024 yields relative humidity (%).

    static func parseHumidity(_ packet: Data) throws -> Float {
        guard packet.count >= 6 else {
            throw MWError.operationFailed("Packet too short for humidity: \(packet.count) bytes")
        }
        let raw = parseUInt32LE(packet, offset: 2)
        return Float(raw) / 1024.0
    }

    // MARK: - Debug — stack overflow state
    //
    // Response shape per C++ `overflow_status_received` (debug.cpp):
    //   [module=0xFE, register=0x89, assert_en, length_lo, length_hi]
    // length is a little-endian UInt16 representing the stack high-water mark.

    static func parseOverflowState(_ packet: Data) throws -> MWDebug.OverflowState {
        guard packet.count >= 5 else {
            throw MWError.operationFailed("Packet too short for OverflowState: \(packet.count) bytes")
        }
        let assertEn = packet[2]
        let length = parseUInt16LE(packet, offset: 3)
        return MWDebug.OverflowState(length: length, assertEnabled: assertEn != 0)
    }

    // MARK: - Debug — schedule queue usage
    //
    // Response shape per C++ `schedule_queue_status_received` (debug.cpp):
    //   [module=0xFE, register=0x8A, <raw payload bytes...>]
    // Routed through DataInterpreter::BYTE_ARRAY — no structured decoding, we
    // just strip the 2-byte header.

    static func parseScheduleQueueUsage(_ packet: Data) throws -> [UInt8] {
        guard packet.count >= 2 else {
            throw MWError.operationFailed("Packet too short for schedule queue usage: \(packet.count) bytes")
        }
        return Array(packet.dropFirst(2))
    }

    // MARK: - MAC address (settings rev ≥ 2)
    //
    // The payload is 6 bytes (older firmware) or 7 bytes with a leading
    // address-type byte (current firmware — `0x01` = random static). Mirrors
    // C++ `convert_to_mac_address`, which does `offset = len == 7 ? 1 : 0`.
    // The 6 MAC bytes are little-endian; the canonical "AA:BB:CC:DD:EE:FF"
    // form reverses them.
    //
    // Python reference (`test_settings.py::test_mac_address`, 7-byte form):
    //   b'\x11\x8b\x01\x07\x7b\x52\x8f\xc9\xe8' → "E8:C9:8F:52:7B:07"
    static func parseMacAddress(_ packet: Data) throws -> String {
        guard packet.count >= 8 else {
            throw MWError.operationFailed("Packet too short for MAC address: \(packet.count) bytes")
        }
        // Skip the address-type byte when present (payload of 7+ bytes).
        let macOffset = packet.count >= 9 ? 3 : 2
        let start = packet.startIndex + macOffset
        let macBytes = (0..<6).map { packet[start + $0] }.reversed()
        return macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Battery

    static func parseBatteryState(_ packet: Data) throws -> BatteryState {
        guard packet.count >= 5 else {
            throw MWError.operationFailed("Packet too short for battery: \(packet.count) bytes")
        }
        let charge  = packet[2]
        let voltage = parseUInt16LE(packet, offset: 3)
        return BatteryState(voltage: voltage, charge: charge)
    }

    // MARK: - Little-endian encoding

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    // MARK: - Log entry (raw download)
    // Raw 9-byte entry: [id_reset_uid, tick(4 LE), data(4 LE)].
    // Total = 1 + 4 + 4 = 9 bytes per entry. The firmware bundles 1 or 2
    // entries in a single BLE notification (preceded by a 2-byte
    // [module, register] header), so a paired notification is 20 bytes
    // and a single-entry notification is 11 bytes.
    //
    // History: an earlier draft assumed a 24-bit tick (3 bytes) for an
    // 8-byte entry, but observed BLE notifications carrying paired
    // entries are 20 bytes (2 + 9 + 9), and the inter-sample tick deltas
    // at 1 Hz only resolve to ~1000 ms when the tick is read as 32-bit
    // LE from bytes 1..4. See `metawear/core/cpp/logging.cpp` —
    // `LOG_ENTRY_SIZE = 9` — and the byte-level protocol reference
    // (`docs/protocol-reference.md`).

    static let msPerTick: Double = (48.0 / 32768.0) * 1000.0  // ≈ 1.4648 ms/tick

    static func parseLogEntry(_ packet: Data) throws -> (id: UInt8, resetUID: UInt8, tick: UInt32, rawData: UInt32) {
        guard packet.count >= 9 else {
            throw MWError.operationFailed("Log entry too short: \(packet.count) bytes")
        }
        // Guarantee zero-based indexing — `parseAll` slices via
        // `notification.advanced(by:)` which on some Foundation builds
        // preserves the original buffer indices, and `parseUInt32LE`
        // below assumes zero-based.
        let p = Data(packet)
        let idByte   = p[0]
        let id       = idByte & 0x1F
        let resetUID = (idByte >> 5) & 0x07
        // Tick is 32-bit little-endian stored in bytes 1..4
        let tick     = parseUInt32LE(p, offset: 1)
        let rawData  = parseUInt32LE(p, offset: 5)
        return (id, resetUID, tick, rawData)
    }
}
