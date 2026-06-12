import Testing
import Foundation
@testable import MetaWear

// MARK: - Helpers

private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = MockBLETransport()
    await transport.setReadResponse(Data("MbientLab".utf8),   for: MWUUIDs.manufacturerName)
    await transport.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await transport.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await transport.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await transport.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)

    let device = MetaWearDevice(identifier: UUID(), transport: transport)
    // Continuously poll for discovery reads — a one-shot 15 ms sleep races
    // against parallel-test load and silently drops responses when CPU is
    // busy (every fix here mirrors the proven pattern in MWFactoryResetTests).
    let discovery = Task {
        var responded = Set<Data>()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let cmds = await transport.writtenCommands
            for cmd in cmds {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !responded.contains(cmd) else { continue }
                responded.insert(cmd)
                let impl: UInt8 = [0x03, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

/// Kick off startLogging while injecting the logger-ID responses it needs.
/// The injector runs in the background; we directly await startLogging so all
/// its write commands complete before returning.
///
/// Firmware response shape: `[0x0B, 0x02, logger_id]` — register byte has bit-7
/// CLEAR (it's a plain notification, not a read response). An earlier version of
/// this mock incorrectly used `0x82`, which only worked because the SDK was
/// using `writeAndRead` instead of `writeAndAwaitNotification` — both bugs
/// cancelled out in unit tests but timed out against real hardware.
private func startLogging<L: MWLoggable>(
    _ loggable: L,
    on device: MetaWearDevice,
    transport: MockBLETransport,
    loggerIDs: [UInt8] = [0x00, 0x01]
) async throws {
    let injector = Task {
        for id in loggerIDs {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await transport.inject(notification: Data([0x0B, 0x02, id]), to: MWUUIDs.notify)
        }
    }
    defer { injector.cancel() }
    try await device.startLogging(loggable)
}

// MARK: - startLogging command tests

@Suite("MetaWearDevice — startLogging Commands")
struct StartLoggingCommandTests {

    @Test func startLogging_sendsEnableLoggingCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        let commands = await transport.writtenCommands
        let enableLogging = commands.first {
            $0.count >= 3 && $0[0] == 0x0B && $0[1] == 0x01 && $0[2] == 0x01
        }
        #expect(enableLogging != nil, "startLogging must send [0x0B, 0x01, 0x01]")
    }

    @Test func startLogging_sendsCircularBufferCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        let commands = await transport.writtenCommands
        let circularBuffer = commands.first {
            $0.count >= 3 && $0[0] == 0x0B && $0[1] == 0x0B && $0[2] == 0x01
        }
        #expect(circularBuffer != nil, "startLogging must send circular buffer enable [0x0B, 0x0B, 0x01]")
    }

    @Test func startLogging_subscribesEachChunk() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        let commands = await transport.writtenCommands
        // Logger subscribe commands: [0x0B, 0x02, module, register, 0xFF, packed_byte]
        let subscriptions = commands.filter {
            $0.count >= 2 && $0[0] == 0x0B && $0[1] == 0x02
        }
        // Accelerometer has 2 chunks → 2 subscribe commands
        #expect(subscriptions.count == 2)
    }

    /// Regression test: the packed byte the SDK puts on the wire must match the
    /// C++ encoding `((length - 1) << 5) | offset` (datasignal.cpp:162,
    /// logging.cpp:868). An earlier version of the SDK had the bit-fields
    /// swapped, which produced wrong packing the firmware silently accepted
    /// but couldn't reassemble. Lock the correct shape in.
    @Test func startLogging_packedByteOnWire_matchesCppEncoding() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        let commands = await transport.writtenCommands
        // Subscribe wire shape: [0x0B, 0x02, module, register, 0xFF, packed]
        let accelSubs = commands.filter {
            $0.count == 6 &&
            $0[0] == 0x0B && $0[1] == 0x02 &&
            $0[2] == MWModule.accelerometer.rawValue &&
            $0[4] == 0xFF
        }
        #expect(accelSubs.count == 2, "Expected exactly 2 subscribe commands for 2 accel chunks")

        // The two accel chunks are (offset=0, length=4) and (offset=4, length=2).
        // Subscriptions are issued in declaration order, so byte 5 of each:
        //   Chunk 0 → ((4-1) << 5) | 0 = 0x60
        //   Chunk 1 → ((2-1) << 5) | 4 = 0x24
        let packedBytes = accelSubs.map { $0[5] }
        #expect(packedBytes.contains(0x60), "Missing packed byte 0x60 (chunk 0,4)")
        #expect(packedBytes.contains(0x24), "Missing packed byte 0x24 (chunk 4,2)")
        // Lock out the legacy buggy values.
        #expect(!packedBytes.contains(0x03), "0x03 is the legacy buggy chunk-0 packing")
        #expect(!packedBytes.contains(0x81), "0x81 is the legacy buggy chunk-1 packing")
    }

    @Test func startLogging_transitionsToLogging() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        #expect(await device.state == .logging)
    }

    @Test func stopLogging_sendsStopCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        try await device.stopLogging(sensor)

        let commands = await transport.writtenCommands
        let stopLogging = commands.first {
            $0.count >= 3 && $0[0] == 0x0B && $0[1] == 0x01 && $0[2] == 0x00
        }
        #expect(stopLogging != nil, "stopLogging must send [0x0B, 0x01, 0x00]")
        #expect(await device.state == .idle)
    }

    @Test func startLogging_notIdle_throws() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)
        // Already logging — second call should throw
        do {
            try await startLogging(sensor, on: device, transport: transport)
            Issue.record("Expected invalidState error")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    /// Verifies the documented "multi-sensor stacking" design: two distinct
    /// sensors can be logged in the same session by calling `startLogging`
    /// once per sensor while the device is already in `.logging`. The duplicate
    /// guard rejects same-signal stacking (covered by `startLogging_notIdle_throws`
    /// above); this test confirms different-signal stacking is accepted and that
    /// both sensors' subscriptions + start commands actually reach the wire.
    @Test func startLogging_twoDistinctSensors_bothSubscribe() async throws {
        let (device, transport) = try await connectedDevice()
        let accel = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        let gyro  = MWGyroscopeBMI160(odr: .hz100, range: .dps2000)

        try await startLogging(accel, on: device, transport: transport,
                               loggerIDs: [0x00, 0x01])
        try await startLogging(gyro,  on: device, transport: transport,
                               loggerIDs: [0x02, 0x03])

        let cmds = await transport.writtenCommands

        // Subscription wire shape: [0x0B, 0x02, sensor_module, data_register, 0xFF, packed].
        // Each sensor splits its 6-byte XYZ payload into two chunks (default
        // MWLoggable.logDataChunks: [(0,4), (4,2)]) → 2 subscriptions per sensor.
        let accelSubs = cmds.filter {
            $0.count >= 6 && $0[0] == 0x0B && $0[1] == 0x02
                && $0[2] == MWModule.accelerometer.rawValue
        }
        let gyroSubs = cmds.filter {
            $0.count >= 6 && $0[0] == 0x0B && $0[1] == 0x02
                && $0[2] == MWModule.gyro.rawValue
        }
        #expect(accelSubs.count == 2, "expected 2 accelerometer chunk subscriptions")
        #expect(gyroSubs.count  == 2, "expected 2 gyroscope chunk subscriptions")

        // Both sensors must be hardware-started (proves the call advanced past
        // the subscription stage on each invocation, not just the first).
        #expect(cmds.contains(MWPacket.command(.accelerometer, 0x01, [0x01])),
                "accelerometer start command must reach the wire")
        #expect(cmds.contains(MWPacket.command(.gyro, 0x01, [0x01])),
                "gyroscope start command must reach the wire")

        #expect(await device.state == .logging)
    }
}

// MARK: - RawLogEntry parsing

@Suite("RawLogEntry — Parsing")
struct RawLogEntryParsingTests {

    @Test func parseAll_singleEntry() throws {
        // 9-byte entry layout: [id, tick(4 LE), data(4 LE)].
        // Header [0x0B, 0x07] + entry: id=0x05, tick=1(4 LE), data=0x3412CDAB
        let notification = Data([0x0B, 0x07,
                                 0x05, 0x01, 0x00, 0x00, 0x00,
                                 0xAB, 0xCD, 0x12, 0x34])
        #expect(notification.count == 11)
        let entries = try RawLogEntry.parseAll(from: notification)
        #expect(entries.count == 1)
        #expect(entries[0].id == (0x05 & 0x1F))
        #expect(entries[0].tick == 1)
        #expect(entries[0].rawData == 0x3412CDAB)
    }

    @Test func parseAll_doubleEntry() throws {
        var notification = Data([0x0B, 0x07])
        // Entry 1: id=0x00, tick=1 (4 LE), rawData=0x11223344
        notification += Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x44, 0x33, 0x22, 0x11])
        // Entry 2: id=0x01, tick=2 (4 LE), rawData=0x55667788
        notification += Data([0x01, 0x02, 0x00, 0x00, 0x00, 0x88, 0x77, 0x66, 0x55])
        #expect(notification.count == 20)

        let entries = try RawLogEntry.parseAll(from: notification)
        #expect(entries.count == 2)
        #expect(entries[0].id == 0x00 && entries[0].tick == 1)
        #expect(entries[0].rawData == 0x11223344)
        #expect(entries[1].id == 0x01 && entries[1].tick == 2)
        #expect(entries[1].rawData == 0x55667788)
    }

    @Test func parseAll_tooShort_returnsEmpty() throws {
        // Header-only (2 bytes) — below the 9-byte entry threshold.
        let entries = try RawLogEntry.parseAll(from: Data([0x0B, 0x07]))
        #expect(entries.isEmpty)
    }

    @Test func parseAll_epochMs_matchesTick() throws {
        // Entry: id=0x00, tick=2 (4 LE), data=0
        let notification = Data([0x0B, 0x07,
                                 0x00, 0x02, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00])
        let entries = try RawLogEntry.parseAll(from: notification)
        let expected = Double(2) * MWPacketParser.msPerTick
        #expect(abs(entries[0].epochMs - expected) < 0.001)
    }

    @Test func parseAll_realHardwareNotification() throws {
        // Captured from a 1 Hz throttled euler download: paired entries at
        // tick 0x003B9F53 with logger ids 0xC0 and 0xC1 (id=0/1, resetUID=6).
        let notification = Data([
            0x0B, 0x07,
            0xC0, 0x53, 0x9F, 0x3B, 0x00, 0xA4, 0xFD, 0xB3, 0x43,
            0xC1, 0x53, 0x9F, 0x3B, 0x00, 0x2E, 0x43, 0x68, 0x41
        ])
        #expect(notification.count == 20)
        let entries = try RawLogEntry.parseAll(from: notification)
        #expect(entries.count == 2)
        #expect(entries[0].id == 0x00)
        #expect(entries[0].resetUID == 0x06)
        #expect(entries[0].tick == 0x003B_9F53)
        #expect(entries[1].id == 0x01)
        #expect(entries[1].resetUID == 0x06)
        #expect(entries[1].tick == entries[0].tick)
    }
}

// MARK: - Log chunk configuration

@Suite("MWLoggable — Log Data Chunks")
struct LogDataChunkTests {

    @Test func accelerometer_hasTwoChunks() {
        let chunks = MWAccelerometerBMI160(odr: .hz100, range: .g2).logDataChunks
        #expect(chunks.count == 2)
        #expect(chunks[0].offset == 0 && chunks[0].length == 4)
        #expect(chunks[1].offset == 4 && chunks[1].length == 2)
    }

    @Test func gyroscope_hasTwoChunks() {
        let chunks = MWGyroscopeBMI160(odr: .hz100, range: .dps2000).logDataChunks
        #expect(chunks.count == 2)
        #expect(chunks[0].length == 4)
        #expect(chunks[1].length == 2)
    }

    @Test func accel_chunkPackedBytes_areCorrect() {
        let chunks = MWAccelerometerBMI160(odr: .hz100, range: .g2).logDataChunks
        // C++ packing: ((length - 1) << 5) | offset
        //   datasignal.cpp:162 / logging.cpp:868 in metawear-cpp-sdk
        // Chunk 0: ((length=4 - 1) << 5) | offset=0 = 0x60
        #expect(((chunks[0].length &- 1) << 5) | chunks[0].offset == 0x60)
        // Chunk 1: ((length=2 - 1) << 5) | offset=4 = 0x24
        #expect(((chunks[1].length &- 1) << 5) | chunks[1].offset == 0x24)
    }
}

// MARK: - Log sample decode

@Suite("MWLoggable — Log Sample Decode")
struct LogSampleDecodeTests {

    @Test func accel_parseLogSample_decodesXYZ() throws {
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)  // scale = 16384
        // x=1g (16384=0x4000 LE), y=-1g (-16384=0xC000 LE), z=0.5g (8192=0x2000 LE)
        let data = Data([0x00, 0x40,  0x00, 0xC0,  0x00, 0x20])
        let sample = try sensor.parseLogSample(from: data)
        #expect(abs(sample.x - 1.0)   < 0.001)
        #expect(abs(sample.y - (-1.0)) < 0.001)
        #expect(abs(sample.z - 0.5)   < 0.001)
    }

    @Test func accel_reassembleAndDecode() throws {
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)  // scale = 16384
        // Two 9-byte log entries for the same sample at tick=1
        // (layout: 1 byte id + 4 byte tick LE + 4 byte data LE):
        // Chunk 0 (logger ID 0): x=1g (0x4000), y=0g (0x0000) → rawData=0x00004000
        // Chunk 1 (logger ID 1): z=0.5g (0x2000), padding=0x0000 → rawData=0x00002000
        let entries: [RawLogEntry] = [
            try RawLogEntry(entryBytes: Data([0x00, 0x01, 0x00, 0x00, 0x00,  0x00, 0x40, 0x00, 0x00])),
            try RawLogEntry(entryBytes: Data([0x01, 0x01, 0x00, 0x00, 0x00,  0x00, 0x20, 0x00, 0x00])),
        ]

        // Reassemble manually
        let chunks: [(id: UInt8, byteCount: Int)] = [(id: 0, byteCount: 4), (id: 1, byteCount: 2)]
        var assembled = Data()
        for chunk in chunks {
            let entry = entries.first { $0.id == chunk.id }!
            var raw = entry.rawData.littleEndian
            let bytes = withUnsafeBytes(of: &raw) { Data($0.prefix(chunk.byteCount)) }
            assembled.append(bytes)
        }
        // assembled = [0x00, 0x40, 0x00, 0x00, 0x00, 0x20] = x=0x4000, y=0x0000, z=0x2000
        let sample = try sensor.parseLogSample(from: assembled)
        #expect(abs(sample.x - 1.0) < 0.001)
        #expect(abs(sample.y)       < 0.001)
        #expect(abs(sample.z - 0.5) < 0.001)
    }
}

// MARK: - flushLogPage

/// Connects like `connectedDevice()` but overrides the logging module's discovery
/// response so `modules[.logging].revision == rev` and `isPresent == true`.
private func connectedDevice(loggingRevision rev: UInt8) async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = MockBLETransport()
    await transport.setReadResponse(Data("MbientLab".utf8),   for: MWUUIDs.manufacturerName)
    await transport.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await transport.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await transport.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await transport.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)

    let device = MetaWearDevice(identifier: UUID(), transport: transport)
    let discovery = Task {
        var responded = Set<Data>()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let cmds = await transport.writtenCommands
            for cmd in cmds {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !responded.contains(cmd) else { continue }
                responded.insert(cmd)
                if cmd[0] == 0x0B {
                    // Logging: present with the requested revision
                    await transport.inject(notification: Data([0x0B, 0x80, 0x00, rev]), to: MWUUIDs.notify)
                } else {
                    let impl: UInt8 = [0x03, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                    await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
                }
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

@Suite("MetaWearDevice — flushLogPage")
struct FlushLogPageTests {

    // On MMS (logging revision == 3) flushLogPage sends [0x0B, 0x10, 0x01].
    @Test func flushLogPage_sendsCommand_whenMMS() async throws {
        let (device, transport) = try await connectedDevice(loggingRevision: 3)
        let before = await transport.writtenCommands.count

        let didSend = try await device.flushLogPage()
        #expect(didSend)

        let after = await transport.writtenCommands
        let flushCmd = after[before...].first {
            $0 == Data([0x0B, 0x10, 0x01])
        }
        #expect(flushCmd != nil, "flushLogPage must send [0x0B, 0x10, 0x01] on MMS")
    }

    // Revision ≥ 3 should also send (forward-compat with future MMS revisions).
    @Test func flushLogPage_sendsCommand_whenRevisionAbove3() async throws {
        let (device, transport) = try await connectedDevice(loggingRevision: 5)
        let before = await transport.writtenCommands.count

        let didSend = try await device.flushLogPage()
        #expect(didSend)

        let after = await transport.writtenCommands
        #expect(after[before...].contains(Data([0x0B, 0x10, 0x01])))
    }

    // On MMRL / pre-MMS firmware, flushLogPage is a no-op (matches C++ behavior).
    @Test func flushLogPage_noOp_whenNotMMS() async throws {
        let (device, transport) = try await connectedDevice(loggingRevision: 2)
        let before = await transport.writtenCommands.count

        let didSend = try await device.flushLogPage()
        #expect(!didSend)

        let after = await transport.writtenCommands
        let flushCmd = after[before...].first {
            $0.count >= 2 && $0[0] == 0x0B && $0[1] == 0x10
        }
        #expect(flushCmd == nil, "flushLogPage must not write anything on non-MMS boards")
    }

    // When the logging module isn't present at all (impl=0xFF) flushLogPage no-ops.
    @Test func flushLogPage_noOp_whenLoggingAbsent() async throws {
        let (device, transport) = try await connectedDevice()  // default: logging absent
        let before = await transport.writtenCommands.count

        let didSend = try await device.flushLogPage()
        #expect(!didSend)

        let after = await transport.writtenCommands
        #expect(!after[before...].contains { $0.count >= 2 && $0[0] == 0x0B && $0[1] == 0x10 })
    }
}

// MARK: - clearLog

@Suite("MetaWearDevice — clearLog")
struct ClearLogTests {

    @Test func clearLog_sendsClearCommand() async throws {
        let (device, transport) = try await connectedDevice()
        try await device.clearLog()

        let commands = await transport.writtenCommands
        let clearCmd = commands.first {
            $0.count == 6 && $0[0] == 0x0B && $0[1] == 0x09 &&
            $0[2] == 0xFF && $0[3] == 0xFF && $0[4] == 0xFF && $0[5] == 0xFF
        }
        #expect(clearCmd != nil, "clearLog must send [0x0B, 0x09, 0xFF, 0xFF, 0xFF, 0xFF]")
    }

    @Test func clearLog_whenNotIdle_throws() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        do {
            try await device.clearLog()
            Issue.record("Expected invalidState error")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }
}
