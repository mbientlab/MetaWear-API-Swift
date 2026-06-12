import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import MetaWear

// MARK: - Helpers

/// Build a MockBLETransport pre-loaded with the DIS characteristic responses
/// needed by MetaWearDevice.initialize() and stub module discovery replies.
private func makeConnectableTransport() async -> MockBLETransport {
    let t = MockBLETransport()
    await t.setReadResponse(Data("MbientLab".utf8), for: MWUUIDs.manufacturerName)
    await t.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await t.setReadResponse(Data("A0B1C2".utf8),       for: MWUUIDs.serialNumber)
    await t.setReadResponse(Data("1.5.0".utf8),        for: MWUUIDs.firmwareRevision)
    await t.setReadResponse(Data("0.4".utf8),          for: MWUUIDs.hardwareRevision)
    return t
}

/// After calling connect(), module discovery fires concurrent reads. This task
/// continuously polls writtenData and injects a stub response the first time
/// it sees each module-info read. Polling (rather than a one-shot 15 ms sleep)
/// keeps the helper robust under heavy parallel-test load — when CPU is busy,
/// `connect()` may not write its reads within any fixed delay, and the old
/// fire-once pattern would silently drop them.
private func autoReplyModuleDiscovery(transport: MockBLETransport) -> Task<Void, Never> {
    Task {
        var responded = Set<Data>()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)   // 3ms poll
            let written = await transport.writtenData
            for (cmd, _, _) in written {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !responded.contains(cmd) else { continue }
                responded.insert(cmd)
                let moduleId = cmd[0]
                // impl=0x01 (present) for accelerometer/gyro/baro/magnet/fusion; 0xFF otherwise
                let present: Set<UInt8> = [0x03, 0x13, 0x12, 0x15, 0x19]
                let impl: UInt8 = present.contains(moduleId) ? 0x01 : 0xFF
                await transport.inject(notification: Data([moduleId, 0x80, impl, 0x00]),
                                       to: MWUUIDs.notify)
            }
        }
    }
}

/// Same shape as `autoReplyModuleDiscovery` but every module is reported
/// absent (impl=0xFF). Used by tests that want to exercise the "module not
/// present" code paths.
private func autoReplyAllAbsent(transport: MockBLETransport) -> Task<Void, Never> {
    Task {
        var responded = Set<Data>()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let written = await transport.writtenData
            for (cmd, _, _) in written {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !responded.contains(cmd) else { continue }
                responded.insert(cmd)
                await transport.inject(
                    notification: Data([cmd[0], 0x80, 0xFF, 0x00]),
                    to: MWUUIDs.notify
                )
            }
        }
    }
}

// MARK: - MockBLETransport convenience

extension MockBLETransport {
    func setReadResponse(_ data: Data, for uuid: CBUUID) {
        readResponses[uuid] = data
    }
}

// MARK: - Connection and state

@Suite("MetaWearDevice — Connection")
struct DeviceConnectionTests {

    @Test func connect_transitionsToIdle() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }

        try await device.connect()
        let state = await device.state
        #expect(state == .idle)
    }

    @Test func connect_populatesDeviceInfo() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }

        try await device.connect()
        let info = await device.deviceInfo
        #expect(info?.manufacturer == "MbientLab")
        #expect(info?.firmwareRevision == "1.5.0")
    }

    @Test func connect_whenAlreadyConnected_throws() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }

        try await device.connect()

        // Second connect should throw .invalidState
        do {
            try await device.connect()
            Issue.record("Expected invalidState error on second connect")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }
    }

    @Test func connect_whileAlreadyConnecting_throws() async throws {
        let transport = await makeConnectableTransport()
        // Widen the connecting window so a concurrent caller sees state == .connecting
        await transport.setConnectDelay(.milliseconds(50))
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }

        // Launch first connect in background; it will sit in transport.connect for 50ms.
        let firstConnect = Task { try await device.connect() }
        defer { firstConnect.cancel() }

        // Yield so the first connect can acquire the actor and set state = .connecting.
        try await Task.sleep(nanoseconds: 5_000_000)

        // A second concurrent connect must be rejected.
        do {
            try await device.connect()
            Issue.record("Expected invalidState error while first connect is in flight")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error type: \(err)") }
        }

        try await firstConnect.value
    }

    @Test func disconnect_transitionsToDisconnected() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }

        try await device.connect()
        try await device.disconnect()
        let state = await device.state
        #expect(state == .disconnected)
    }

    @Test func connect_whenTransportFails_rethrows() async throws {
        let transport = await makeConnectableTransport()
        await transport.setConnectError(MWError.operationFailed("BLE timeout"))
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        do {
            try await device.connect()
            Issue.record("Expected connect to throw")
        } catch {
            // Expected — transport error propagates
        }
    }
}

// MARK: - Streaming state guard

@Suite("MetaWearDevice — Streaming Guard")
struct DeviceStreamingGuardTests {

    private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)
        let discovery = autoReplyModuleDiscovery(transport: transport)
        try await device.connect()
        discovery.cancel()
        return (device, transport)
    }

    @Test func stream_transitionsToStreaming() async throws {
        let (device, _) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        _ = try await device.startStream(sensor, usePacked: false)
        let state = await device.state
        #expect(state == .streaming)
    }

    @Test func stream_whenNotIdle_throws() async throws {
        let (device, _) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)

        _ = try await device.startStream(sensor, usePacked: false)  // → .streaming

        do {
            _ = try await device.startStream(sensor, usePacked: false)  // must throw
            Issue.record("Expected invalidState on second stream call")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    @Test func stream_sendsConfigureEnableStartCommands() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        _ = try await device.startStream(sensor, usePacked: false)

        let written = await transport.writtenData
        let commands = written.map { $0.0 }

        // configureCommands + enableCommand + startCommand
        let expected = sensor.configureCommands + [sensor.enableCommand, sensor.startCommand]
        for cmd in expected {
            #expect(commands.contains(cmd))
        }
    }

    @Test func stopStreaming_transitionsBackToIdle() async throws {
        let (device, _) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        _ = try await device.startStream(sensor, usePacked: false)

        try await device.stopStreaming(sensor)
        let state = await device.state
        #expect(state == .idle)
    }

    @Test func stopStreaming_sendsStopAndDisableCommands() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        _ = try await device.startStream(sensor, usePacked: false)

        let beforeCount = await transport.writtenData.count
        try await device.stopStreaming(sensor)

        let written = await transport.writtenData
        let afterCmds = written.dropFirst(beforeCount).map { $0.0 }
        #expect(afterCmds.contains(sensor.stopCommand))
        #expect(afterCmds.contains(sensor.disableCommand))
    }
}

// MARK: - Logging state guard

@Suite("MetaWearDevice — Logging Guard")
struct DeviceLoggingGuardTests {

    private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)
        let discovery = autoReplyModuleDiscovery(transport: transport)
        try await device.connect()
        discovery.cancel()
        return (device, transport)
    }

    /// startLogging subscribes each data chunk and waits for a logger-ID response.
    /// Inject one [0x0B, 0x02, id] per chunk to unblock it.
    /// The firmware reply is a plain notification (bit-7 clear on the register
    /// byte) — not a read response.
    private func startLogging<L: MWLoggable>(
        _ loggable: L,
        on device: MetaWearDevice,
        transport: MockBLETransport,
        ids: [UInt8] = [0x00, 0x01]
    ) async throws {
        let injector = Task {
            for id in ids {
                try? await Task.sleep(nanoseconds: 10_000_000)
                await transport.inject(notification: Data([0x0B, 0x02, id]), to: MWUUIDs.notify)
            }
        }
        defer { injector.cancel() }
        try await device.startLogging(loggable)
    }

    @Test func startLogging_transitionsToLogging() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)
        #expect(await device.state == .logging)
    }

    @Test func startLogging_whenNotIdle_throws() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)

        do {
            try await device.startLogging(sensor)
            Issue.record("Expected invalidState")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    @Test func stopLogging_transitionsBackToIdle() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        try await startLogging(sensor, on: device, transport: transport)
        try await device.stopLogging(sensor)
        #expect(await device.state == .idle)
    }
}

// MARK: - One-shot reads

@Suite("MetaWearDevice — One-Shot Reads")
struct DeviceOneShotReadTests {

    private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)
        let discovery = autoReplyModuleDiscovery(transport: transport)
        try await device.connect()
        discovery.cancel()
        return (device, transport)
    }

    @Test func readBattery_parsesBatteryState() async throws {
        let (device, transport) = try await connectedDevice()

        // Inject the battery response after the read command fires.
        // BATTERY_STATE is register 0x0C on the settings module — the firmware
        // emits the read response as [0x11, 0x8C, charge, volt_lo, volt_hi].
        let batteryTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000)
            // charge=0x55 (85), voltage=0x0F9C (3996)
            await transport.inject(
                notification: Data([0x11, 0x8C, 0x55, 0x9C, 0x0F]),
                to: MWUUIDs.notify
            )
        }
        defer { batteryTask.cancel() }

        let battery = try await device.readBattery()
        #expect(battery.charge == 85)
        #expect(battery.voltage == 3996)
    }

    @Test func readTemperature_parsesTemperature() async throws {
        let (device, transport) = try await connectedDevice()

        // raw int16 = 200 → 200/8 = 25.0°C
        // [temp module=0x04, reg 0x81 (0x01|0x80), channel, 0xC8, 0x00]
        let tempTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x04, 0x81, 0x00, 0xC8, 0x00]),
                to: MWUUIDs.notify
            )
        }
        defer { tempTask.cancel() }

        let celsius = try await device.readTemperature()
        #expect(celsius == 25.0)
    }
}

// MARK: - Module helpers

@Suite("MetaWearDevice — Module Helpers")
struct DeviceModuleHelperTests {

    @Test func hasGyroscope_trueWhenPresent() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)
        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }
        try await device.connect()

        // autoReplyModuleDiscovery marks gyro (0x13) as present
        let has = await device.hasGyroscope
        #expect(has == true)
    }

    @Test func hasGyroscope_falseWhenAbsent() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        // Reply with all modules absent (impl=0xFF)
        let allAbsent = autoReplyAllAbsent(transport: transport)
        defer { allAbsent.cancel() }

        try await device.connect()
        let has = await device.hasGyroscope
        #expect(has == false)
    }
}

// MARK: - Sensor fusion calibration

@Suite("MetaWearDevice — readFusionCalibration")
struct FusionCalibrationTests {

    @Test func readFusionCalibration_parsesAllThreeChannels() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }
        try await device.connect()

        // Inject calibration response: [0x19, 0x8B, accel=2, gyro=3, mag=1]
        let calibPacket = Data([0x19, 0x8B, 0x02, 0x03, 0x01])
        let injector = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(notification: calibPacket, to: MWUUIDs.notify)
        }
        defer { injector.cancel() }

        let cal = try await device.readFusionCalibration()
        #expect(cal.accelerometer == 2)
        #expect(cal.gyroscope     == 3)
        #expect(cal.magnetometer  == 1)
    }

    @Test func readFusionCalibration_allFullyCalibrated() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)
        defer { discovery.cancel() }
        try await device.connect()

        let calibPacket = Data([0x19, 0x8B, 0x03, 0x03, 0x03])
        let injector = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(notification: calibPacket, to: MWUUIDs.notify)
        }
        defer { injector.cancel() }

        let cal = try await device.readFusionCalibration()
        #expect(cal.accelerometer == 3)
        #expect(cal.gyroscope     == 3)
        #expect(cal.magnetometer  == 3)
    }

    @Test func readFusionCalibration_throwsWhenModuleAbsent() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        // Reply all modules absent
        let allAbsent = autoReplyAllAbsent(transport: transport)
        defer { allAbsent.cancel() }
        try await device.connect()

        do {
            _ = try await device.readFusionCalibration()
            Issue.record("Should have thrown when sensor fusion is absent")
        } catch MWError.operationFailed {
            // Expected
        }
    }
}

// MARK: - makeAccelerometer

@Suite("MetaWearDevice — makeAccelerometer")
struct MakeAccelerometerTests {

    @Test func makeAccelerometer_returnsBMI160_forImpl1() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let discovery = autoReplyModuleDiscovery(transport: transport)  // marks acc as impl=0x01
        defer { discovery.cancel() }
        try await device.connect()

        let acc = await device.makeAccelerometer(odrHz: 100, rangeG: 2)
        #expect(acc != nil)
        if case .bmi160 = acc { /* expected */ }
        else { Issue.record("Expected BMI160, got \(String(describing: acc))") }
    }

    @Test func makeAccelerometer_returnsNil_whenAbsent() async throws {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)

        let allAbsent = autoReplyAllAbsent(transport: transport)
        defer { allAbsent.cancel() }
        try await device.connect()

        let acc = await device.makeAccelerometer()
        #expect(acc == nil)
    }
}

// MARK: - MWCommandSequence dispatch

@Suite("MetaWearDevice — CommandSequence dispatch")
struct DeviceCommandSequenceTests {

    private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
        let transport = await makeConnectableTransport()
        let device = MetaWearDevice(identifier: UUID(), transport: transport)
        let discovery = autoReplyModuleDiscovery(transport: transport)
        try await device.connect()
        discovery.cancel()
        return (device, transport)
    }

    /// Collect only the commands written to the command characteristic,
    /// and only those written *after* the connect() handshake completed.
    private func commandsWrittenAfterConnect(
        _ transport: MockBLETransport
    ) async -> [Data] {
        let written = await transport.writtenData
        return written.compactMap { data, uuid, _ in
            uuid == MWUUIDs.command ? data : nil
        }
    }

    @Test func send_sequence_issuesMultipleWritesInOrder() async throws {
        let (device, transport) = try await connectedDevice()
        let before = await commandsWrittenAfterConnect(transport)

        // Enable wrist gesture emits FEATURE_INTERRUPT_ENABLE then FEATURE_ENABLE.
        try await device.send(MWAccelerometerBMI270Features.EnableWristGesture())

        let after = await commandsWrittenAfterConnect(transport)
        let new = Array(after.dropFirst(before.count))
        #expect(new == [
            Data([0x03, 0x07, 0x10, 0x00]),
            Data([0x03, 0x06, 0x10, 0x00]),
        ])
    }

    @Test func send_sequence_disableNoMotion_writesTwoCommands() async throws {
        let (device, transport) = try await connectedDevice()
        let before = await commandsWrittenAfterConnect(transport)

        try await device.send(MWAccelerometerBMI270Features.DisableNoMotion())

        let after = await commandsWrittenAfterConnect(transport)
        let new = Array(after.dropFirst(before.count))
        #expect(new == [
            Data([0x03, 0x07, 0x00, 0x20]),
            Data([0x03, 0x06, 0x00, 0x20]),
        ])
    }

    @Test func send_sequence_stepCounter_writesAllThreeCommands() async throws {
        let (device, transport) = try await connectedDevice()
        let before = await commandsWrittenAfterConnect(transport)

        try await device.send(
            MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: 1)
        )

        let after = await commandsWrittenAfterConnect(transport)
        let new = Array(after.dropFirst(before.count))
        // interrupt enable, feature enable, config — in that order.
        #expect(new == [
            Data([0x03, 0x07, 0x02, 0x00]),
            Data([0x03, 0x06, 0x02, 0x00]),
            Data([0x03, 0x08, 0x07, 0x00, 0x0E, 0x01, 0x00]),
        ])
    }

    @Test func send_sequence_setScanResponse_long_splitsAcrossRegisters() async throws {
        let (device, transport) = try await connectedDevice()
        let before = await commandsWrittenAfterConnect(transport)

        // 16-byte payload → first 13 bytes go to reg 0x08, remaining 3 to reg 0x07.
        let payload: [UInt8] = Array(0x20...0x2F)
        try await device.send(MWSettings.SetScanResponse(payload))

        let after = await commandsWrittenAfterConnect(transport)
        let new = Array(after.dropFirst(before.count))
        #expect(new.count == 2)
        #expect(new[0] == Data([0x11, 0x08] + Array(payload.prefix(13))))
        #expect(new[1] == Data([0x11, 0x07] + Array(payload.dropFirst(13))))
    }
}

