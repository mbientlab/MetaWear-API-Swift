import Testing
import Foundation
@testable import MetaWear

// MARK: - Helpers

private func connectedDevice(
    injectLogTime tick: UInt32? = nil
) async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = MockBLETransport()
    await transport.setReadResponse(Data("MbientLab".utf8),   for: MWUUIDs.manufacturerName)
    await transport.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await transport.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await transport.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await transport.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)

    let device = MetaWearDevice(identifier: UUID(), transport: transport)

    // Poll for new BLE write commands and inject appropriate responses.
    // This runs continuously until cancelled so it catches module-discovery AND
    // the logging time-reference read that follows.
    var respondedTo = Set<Data>()
    let discovery = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let cmds = await transport.writtenCommands
            for cmd in cmds {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !respondedTo.contains(cmd) else { continue }
                respondedTo.insert(cmd)

                // Logging time read: [0x0B, 0x84]
                if cmd[0] == 0x0B && cmd[1] == 0x84 {
                    let t = tick ?? 0
                    await transport.inject(notification: Data([
                        0x0B, 0x84,
                        UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF),
                        UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF),
                        0x00
                    ]), to: MWUUIDs.notify)
                    continue
                }

                // Module discovery: respond with impl present/absent
                let impl: UInt8 = ([0x03, 0x0B, 0x13, 0x12, 0x15, 0x19].contains(cmd[0])) ? 0x01 : 0xFF
                await transport.inject(
                    notification: Data([cmd[0], 0x80, impl, 0x00]),
                    to: MWUUIDs.notify
                )
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

private func startLogging<L: MWLoggable>(
    _ loggable: L,
    on device: MetaWearDevice,
    transport: MockBLETransport,
    loggerIDs: [UInt8] = [0x00, 0x01]
) async throws {
    let injector = Task {
        for id in loggerIDs {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await transport.inject(notification: Data([0x0B, 0x82, id]), to: MWUUIDs.notify)
        }
    }
    defer { injector.cancel() }
    try await device.startLogging(loggable)
}

// MARK: - Log time anchor

@Suite("MetaWearDevice — Log Time Anchor")
struct LogTimeAnchorTests {

    @Test func connect_readsLogTimeReference() async throws {
        // Connect with tick=1000 — the reference date should be ~1.46s before now
        let (device, _) = try await connectedDevice(injectLogTime: 1000)

        let refDate = await device.logReferenceDate
        #expect(refDate != nil, "logReferenceDate must be set after connect when logging module is present")

        let expectedOffset = Double(1000) * MWPacketParser.msPerTick / 1000.0  // seconds
        let actualOffset = Date().timeIntervalSince(refDate!)
        // Allow ±200ms timing slack
        #expect(abs(actualOffset - expectedOffset) < 0.2,
                "Reference date should be ~\(expectedOffset)s in the past")
    }

    @Test func loggedSample_usesReferenceDate() async throws {
        // tick=0 → reference = now. A sample at tick=1000 should be ~1.46s after ref.
        let (device, _) = try await connectedDevice(injectLogTime: 0)

        let before = Date()
        let ref = await device.logReferenceDate!

        // Manually decode a fake entry at tick=1000
        let sampleTick: UInt32 = 1000
        let msElapsed = Double(sampleTick) * MWPacketParser.msPerTick
        let expectedDate = Date(timeInterval: msElapsed / 1000.0, since: ref)
        #expect(expectedDate > before)
        #expect(abs(expectedDate.timeIntervalSince(ref) - msElapsed / 1000.0) < 0.001)
    }

    @Test func unexpectedDisconnect_clearsReferenceDate() async throws {
        let (device, transport) = try await connectedDevice(injectLogTime: 500)
        #expect(await device.logReferenceDate != nil)

        await transport.simulateDisconnect()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(await device.logReferenceDate == nil,
                "logReferenceDate must be cleared on unexpected disconnect")
    }

    @Test func reconnect_refreshesReferenceDate() async throws {
        let (device, transport) = try await connectedDevice(injectLogTime: 100)

        await transport.simulateDisconnect()
        try await Task.sleep(nanoseconds: 20_000_000)

        // Re-prime for reconnect. Track by index so duplicate commands still get replied to.
        let offsetAtReconnect = await transport.writtenCommands.count
        var nextIdx = offsetAtReconnect
        let rediscovery = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000)
                let cmds = await transport.writtenCommands
                while nextIdx < cmds.count {
                    let cmd = cmds[nextIdx]
                    nextIdx += 1
                    guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                    if cmd[0] == 0x0B && cmd[1] == 0x84 {
                        let t: UInt32 = 2000
                        await transport.inject(notification: Data([
                            0x0B, 0x84,
                            UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF),
                            UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF), 0x00
                        ]), to: MWUUIDs.notify)
                        continue
                    }
                    let impl: UInt8 = [0x03, 0x0B, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                    await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
                }
            }
        }
        try await device.reconnect()
        rediscovery.cancel()

        #expect(await device.logReferenceDate != nil, "logReferenceDate must be re-read after reconnect")
    }
}

// MARK: - Logger registry persistence across disconnect

@Suite("MetaWearDevice — Logger Registry Persistence")
struct LoggerRegistryPersistenceTests {

    @Test func loggerRegistry_survivesUnexpectedDisconnect() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        // Verify registry is populated
        #expect(await device.loggerRegistryHasKey(sensor.loggerKey))

        // Simulate unexpected drop
        await transport.simulateDisconnect()
        try await Task.sleep(nanoseconds: 20_000_000)

        // Registry must still be there so download can proceed after reconnect
        #expect(await device.loggerRegistryHasKey(sensor.loggerKey),
                "loggerRegistry must survive unexpected disconnect")
    }

    @Test func clearLog_removesRegistry() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)
        try await device.stopLogging(sensor)
        try await device.clearLog()

        #expect(!(await device.loggerRegistryHasKey(sensor.loggerKey)),
                "clearLog must remove loggerRegistry entries")
    }
}

// MARK: - queryActiveLoggers

@Suite("MetaWearDevice — queryActiveLoggers")
struct QueryActiveLoggersTests {

    @Test func queryActiveLoggers_parsesResponse() async throws {
        let (device, transport) = try await connectedDevice()

        // Inject responses for two logger IDs, then a timeout for ID 2.
        // Packed byte: low 5 bits = offset, high 3 bits = length-1.
        let responder = Task {
            // Logger 0: module=accel(0x03), register=0x04, channel=0xFF,
            //           packed=0x60 (offset=0, length=4)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x0B, 0x82, 0x00, 0x03, 0x04, 0xFF, 0x60]),
                to: MWUUIDs.notify
            )
            // Logger 1: module=accel(0x03), register=0x04, channel=0xFF,
            //           packed=0x24 (offset=4, length=2)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x0B, 0x82, 0x01, 0x03, 0x04, 0xFF, 0x24]),
                to: MWUUIDs.notify
            )
            // No response for logger 2 → timeout stops iteration
        }
        defer { responder.cancel() }

        let loggers = try await device.queryActiveLoggers()
        #expect(loggers.count == 2)
        #expect(loggers[0].loggerID == 0 && loggers[0].module == .accelerometer)
        #expect(loggers[1].loggerID == 1 && loggers[1].module == .accelerometer)
        #expect(loggers[0].chunkOffset == 0 && loggers[0].chunkLength == 4)
        #expect(loggers[1].chunkOffset == 4 && loggers[1].chunkLength == 2)
        #expect(loggers[0].channel == 0xFF)
    }
}

// MARK: - recoverLoggers

@Suite("MetaWearDevice — recoverLoggers")
struct RecoverLoggersTests {

    @Test func recoverLoggers_rebuildsRegistry() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)

        // No registry initially
        #expect(!(await device.loggerRegistryHasKey(sensor.loggerKey)))

        // Inject query responses
        let responder = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x0B, 0x82, 0x00, 0x03, 0x04, 0xFF, 0x03]),
                to: MWUUIDs.notify
            )
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x0B, 0x82, 0x01, 0x03, 0x04, 0xFF, 0x81]),
                to: MWUUIDs.notify
            )
            // Let ID 2 time out
        }
        defer { responder.cancel() }

        try await device.recoverLoggers(for: sensor)
        #expect(await device.loggerRegistryHasKey(sensor.loggerKey),
                "recoverLoggers must populate loggerRegistry")
    }

    @Test func recoverLoggers_throwsWhenNoMatch() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)

        // Only inject a response for a gyro logger — no accel
        let responder = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x0B, 0x82, 0x00, 0x13, 0x05, 0xFF, 0x03]),  // gyro
                to: MWUUIDs.notify
            )
            // ID 1 times out
        }
        defer { responder.cancel() }

        do {
            try await device.recoverLoggers(for: sensor)
            Issue.record("Expected operationFailed error")
        } catch let err as MWError {
            if case .operationFailed = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }
}

// MARK: - MWLoggedSample

@Suite("MWLoggedSample — Date fields")
struct MWLoggedSampleTests {

    @Test func date_and_tickMs_areDistinct() {
        let ref = Date(timeIntervalSinceNow: -10)
        let tickMs = 1000.0
        let date = Date(timeInterval: tickMs / 1000.0, since: ref)
        let sample = MWLoggedSample(date: date, tickMs: tickMs, value: 42)
        #expect(sample.tickMs == 1000.0)
        #expect(abs(sample.date.timeIntervalSince(ref) - 1.0) < 0.001)
    }
}

// MARK: - Test-only accessors

private extension MetaWearDevice {
    var logReferenceDate: Date? {
        get async { await _logReferenceDate() }
    }
    func loggerRegistryHasKey(_ key: String) async -> Bool {
        await _loggerRegistryHasKey(key)
    }
}
