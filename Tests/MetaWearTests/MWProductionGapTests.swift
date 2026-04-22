import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import MetaWear

// MARK: - Helpers (shared with existing device tests)

private func makeConnectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = MockBLETransport()
    await transport.setReadResponse(Data("MbientLab".utf8),    for: MWUUIDs.manufacturerName)
    await transport.setReadResponse(Data("MetaMotionS".utf8),  for: MWUUIDs.modelNumber)
    await transport.setReadResponse(Data("A0B1C2".utf8),       for: MWUUIDs.serialNumber)
    await transport.setReadResponse(Data("1.5.0".utf8),        for: MWUUIDs.firmwareRevision)
    await transport.setReadResponse(Data("0.4".utf8),          for: MWUUIDs.hardwareRevision)

    let device = MetaWearDevice(identifier: UUID(), transport: transport)

    let discovery = Task {
        try? await Task.sleep(nanoseconds: 15_000_000)
        let written = await transport.writtenData
        for (cmd, _, _) in written {
            guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
            let impl: UInt8 = [0x03, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
            await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

// MARK: - 1. Read timeouts

@Suite("Protocol Layer — Read Timeouts")
struct ReadTimeoutTests {

    @Test func read_timesOut_whenNoResponse() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        // Never inject a response — should timeout
        do {
            _ = try await proto.read(.accelerometer, 0x03)
            Issue.record("Expected timeout error")
        } catch let err as MWError {
            if case .timeout = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    @Test func read_succeedsBeforeTimeout() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        async let response = proto.read(.accelerometer, 0x03)
        try await Task.sleep(nanoseconds: 5_000_000)
        await transport.inject(notification: Data([0x03, 0x83, 0xAB]), to: MWUUIDs.notify)

        let data = try await response
        #expect(data == Data([0x03, 0x83, 0xAB]))
    }

    @Test func timeout_doesNotAffectOtherWaiters() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        // Read on gyro (will timeout) and accel (will get a reply)
        let gyroTask  = Task { try await proto.read(.gyro, 0x01) }
        let accelTask = Task { try await proto.read(.accelerometer, 0x03) }

        try await Task.sleep(nanoseconds: 5_000_000)

        // Only inject the accel reply
        await transport.inject(notification: Data([0x03, 0x83, 0xFF]), to: MWUUIDs.notify)

        // Accel should succeed
        let accelData = try await accelTask.value
        #expect(accelData == Data([0x03, 0x83, 0xFF]))

        // Cancel the gyro task so we don't wait for the full 5s timeout
        gyroTask.cancel()
        _ = try? await gyroTask.value
    }
}

// MARK: - 2. Reconnection

@Suite("MetaWearDevice — Reconnection")
struct ReconnectionTests {

    @Test func unexpectedDisconnect_setsStateToDisconnected() async throws {
        let (device, transport) = try await makeConnectedDevice()
        #expect(await device.state == .idle)

        // Simulate BLE drop
        await transport.simulateDisconnect()
        try await Task.sleep(nanoseconds: 10_000_000)  // let the callback propagate

        #expect(await device.state == .disconnected)
    }

    @Test func unexpectedDisconnect_callsHandler() async throws {
        let (device, transport) = try await makeConnectedDevice()

        let handlerCalled = MWAtomic(false)
        await device.setDisconnectHandler { _ in
            handlerCalled.set(true)
        }

        await transport.simulateDisconnect()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(handlerCalled.value)
    }

    @Test func reconnect_succeedsFromDisconnectedState() async throws {
        let (device, transport) = try await makeConnectedDevice()

        await transport.simulateDisconnect()
        try await Task.sleep(nanoseconds: 10_000_000)

        // Re-prime the transport for reconnect
        let discovery = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)
            let written = await transport.writtenData
            for (cmd, _, _) in written {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                await transport.inject(notification: Data([cmd[0], 0x80, 0x01, 0x00]), to: MWUUIDs.notify)
            }
        }
        try await device.reconnect()
        discovery.cancel()

        #expect(await device.state == .idle)
    }

    @Test func cleanDisconnect_doesNotCallHandler() async throws {
        let (device, _) = try await makeConnectedDevice()

        let handlerCalled = MWAtomic(false)
        await device.setDisconnectHandler { _ in
            handlerCalled.set(true)
        }

        try await device.disconnect()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(!handlerCalled.value)
    }
}

// MARK: - 3. Sensor conflict detection

@Suite("MetaWearDevice — Sensor Conflict Detection")
struct SensorConflictTests {

    @Test func sensorFusion_blocksAccelerometer() async throws {
        let (device, _) = try await makeConnectedDevice()

        // Start sensor fusion
        _ = try await device.stream(MWSensorFusionQuaternion(), usePacked: false)

        // Trying to stream accelerometer should throw
        do {
            _ = try await device.stream(MWAccelerometerBMI160(odr: .hz100, range: .g2), usePacked: false)
            Issue.record("Expected invalidState conflict error")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    @Test func accelerometer_blocksSensorFusion() async throws {
        let (device, _) = try await makeConnectedDevice()

        _ = try await device.stream(MWAccelerometerBMI160(odr: .hz100, range: .g2), usePacked: false)

        do {
            _ = try await device.stream(MWSensorFusionQuaternion(), usePacked: false)
            Issue.record("Expected invalidState conflict error")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    @Test func accelAndGyro_canStreamTogether() async throws {
        let (device, _) = try await makeConnectedDevice()

        _ = try await device.stream(MWAccelerometerBMI160(odr: .hz100, range: .g2), usePacked: false)
        // Gyro and accel are both individual IMU sensors — should NOT conflict
        _ = try await device.stream(MWGyroscopeBMI160(odr: .hz100, range: .dps2000), usePacked: false)

        #expect(await device.state == .streaming)
    }

    @Test func stopStreaming_allowsFusionAfterIMU() async throws {
        let (device, _) = try await makeConnectedDevice()

        let acc = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        _ = try await device.stream(acc, usePacked: false)
        try await device.stopStreaming(acc)

        // Now fusion should be allowed
        _ = try await device.stream(MWSensorFusionQuaternion(), usePacked: false)
        #expect(await device.state == .streaming)
    }
}

// MARK: - 4. Settings commands

@Suite("Settings Commands")
struct SettingsCommandTests {

    @Test func setDeviceName_correctBytes() {
        let cmd = MWSettings.SetDeviceName("MyBoard")
        #expect(cmd.commandData[0] == 0x11)   // settings module
        #expect(cmd.commandData[1] == 0x01)   // DEVICE_NAME register
        let nameBytes = Array("MyBoard".utf8)
        #expect(Array(cmd.commandData.dropFirst(2)) == nameBytes)
    }

    @Test func setDeviceName_truncatesAtMaxLength() {
        // 40-char input should be truncated to 26 bytes of payload (+2 header).
        let long = String(repeating: "A", count: 40)
        let cmd = MWSettings.SetDeviceName(long)
        #expect(cmd.commandData.count == 2 + MWSettings.maxDeviceNameLength)
    }

    @Test func setTXPower_correctByte() {
        let cmd = MWSettings.SetTXPower(.minus4)
        #expect(cmd.commandData == Data([0x11, 0x03, UInt8(bitPattern: -4)]))
    }

    @Test func startAdvertising_command() {
        let cmd = MWSettings.StartAdvertising()
        #expect(cmd.commandData == Data([0x11, 0x05]))
    }

    @Test func setAdvertisingInterval_encodesAs0_625Units() {
        // 417ms / 0.625 = 667.2 → 667 units = 0x029B
        let cmd = MWSettings.SetAdvertisingInterval(intervalMs: 417, timeoutSec: 0)
        #expect(cmd.commandData[0] == 0x11)
        #expect(cmd.commandData[1] == 0x02)
        let units = UInt16(cmd.commandData[2]) | (UInt16(cmd.commandData[3]) << 8)
        #expect(units == UInt16(417 / 0.625))
        #expect(cmd.commandData[4] == 0)  // timeout
    }

    @Test func connectionParams_correctBytes() {
        let cmd = MWSettings.SetConnectionParameters(
            minInterval: 6, maxInterval: 24, latency: 0, timeout: 500
        )
        #expect(cmd.commandData[0] == 0x11)
        #expect(cmd.commandData[1] == 0x09)
        // min=6 LE: [0x06, 0x00]
        #expect(cmd.commandData[2] == 0x06 && cmd.commandData[3] == 0x00)
        // max=24 LE: [0x18, 0x00]
        #expect(cmd.commandData[4] == 0x18 && cmd.commandData[5] == 0x00)
        // latency=0: [0x00, 0x00]
        #expect(cmd.commandData[6] == 0x00 && cmd.commandData[7] == 0x00)
        // timeout=500 LE: [0xF4, 0x01]
        #expect(cmd.commandData[8] == 0xF4 && cmd.commandData[9] == 0x01)
        #expect(cmd.commandData.count == 10)
    }

    @Test func lowLatencyPreset() {
        let cmd = MWSettings.SetConnectionParameters.lowLatency
        #expect(cmd.minInterval == 6)
        #expect(cmd.maxInterval == 6)
        #expect(cmd.latency == 0)
    }

    @Test func powerSavingPreset() {
        let cmd = MWSettings.SetConnectionParameters.powerSaving
        #expect(cmd.latency > 0)
        #expect(cmd.minInterval > 24)
    }

    // --- Reference vectors from MetaWear-SDK-Cpp/test/test_settings.py ---

    // test_set_name: set device name "AntiWare"
    // Expected: [0x11, 0x01, 0x41, 0x6e, 0x74, 0x69, 0x57, 0x61, 0x72, 0x65]
    @Test func setDeviceName_pythonVector_AntiWare() {
        let cmd = MWSettings.SetDeviceName("AntiWare")
        #expect(cmd.commandData == Data([
            0x11, 0x01,
            0x41, 0x6E, 0x74, 0x69, 0x57, 0x61, 0x72, 0x65
        ]))
    }

    // Validating initializer must produce the same wire bytes as the plain one
    // for an accepted name.
    @Test func setDeviceName_validating_AntiWare() throws {
        let cmd = try MWSettings.SetDeviceName(validating: "AntiWare")
        #expect(cmd.commandData == Data([
            0x11, 0x01,
            0x41, 0x6E, 0x74, 0x69, 0x57, 0x61, 0x72, 0x65
        ]))
    }

    // test_set_tx_power: set_tx_power(-20) → [0x11, 0x03, 0xec]
    @Test func setTXPower_pythonVector_minus20() {
        let cmd = MWSettings.SetTXPower(.minus20)
        #expect(cmd.commandData == Data([0x11, 0x03, 0xEC]))
    }

    // test_set_ad_interval (default rev >= 2): set_ad_interval(417, 0)
    // Expected: [0x11, 0x02, 0x9b, 0x02, 0x00]
    // Encoding: 417 ms / 0.625 = 667 units (0x029B), timeout byte = 0.
    @Test func setAdvertisingInterval_pythonVector_417ms_0s() {
        let cmd = MWSettings.SetAdvertisingInterval(intervalMs: 417, timeoutSec: 0)
        #expect(cmd.commandData == Data([0x11, 0x02, 0x9B, 0x02, 0x00]))
    }

    // test_set_ad_interval (Revision1): set_ad_interval(417, 180)
    // Expected: [0x11, 0x02, 0x9b, 0x02, 0xb4]
    @Test func setAdvertisingInterval_pythonVector_rev1_417ms_180s() {
        let cmd = MWSettings.SetAdvertisingInterval(intervalMs: 417, timeoutSec: 180)
        #expect(cmd.commandData == Data([0x11, 0x02, 0x9B, 0x02, 0xB4]))
    }

    // test_set_conn_params: set_connection_parameters(750ms, 1000ms, 128, 16384ms)
    // Expected: [0x11, 0x09, 0x58, 0x02, 0x20, 0x03, 0x80, 0x00, 0x66, 0x06]
    // Swift takes raw 1.25 ms units for min/max and 10 ms units for timeout.
    //   750 / 1.25  = 600 = 0x0258
    //   1000 / 1.25 = 800 = 0x0320
    //   latency     = 128 = 0x0080
    //   16384 / 10  = 1638 ≈ 0x0666
    @Test func setConnectionParameters_pythonVector() {
        let cmd = MWSettings.SetConnectionParameters(
            minInterval: 600,
            maxInterval: 800,
            latency: 128,
            timeout: 1638
        )
        #expect(cmd.commandData == Data([
            0x11, 0x09,
            0x58, 0x02,
            0x20, 0x03,
            0x80, 0x00,
            0x66, 0x06
        ]))
    }

    // test_start_advertising: [0x11, 0x05]
    @Test func startAdvertising_pythonVector() {
        #expect(MWSettings.StartAdvertising().commandData == Data([0x11, 0x05]))
    }

    // test_set_scan_response (21-byte payload, split across PARTIAL_SCAN_RESPONSE (0x08)
    // and SCAN_RESPONSE (0x07)).
    @Test func setScanResponse_pythonVector_splitWrite() {
        let payload: [UInt8] = [
            0x03, 0x03, 0xD8, 0xFE, 0x10, 0x16, 0xD8, 0xFE,
            0x00, 0x12, 0x00, 0x6D, 0x62, 0x69, 0x65, 0x6E,
            0x74, 0x6C, 0x61, 0x62, 0x00
        ]
        let cmds = MWSettings.SetScanResponse(payload).commands
        #expect(cmds.count == 2)
        #expect(cmds[0] == Data([
            0x11, 0x08,
            0x03, 0x03, 0xD8, 0xFE, 0x10, 0x16, 0xD8, 0xFE,
            0x00, 0x12, 0x00, 0x6D, 0x62
        ]))
        #expect(cmds[1] == Data([
            0x11, 0x07,
            0x69, 0x65, 0x6E, 0x74, 0x6C, 0x61, 0x62, 0x00
        ]))
    }

    @Test func setScanResponse_shortPayload_singleWrite() {
        // Short payload (≤ 13 bytes) should emit a single write to register 0x07.
        let payload: [UInt8] = [0x01, 0x02, 0x03]
        let cmds = MWSettings.SetScanResponse(payload).commands
        #expect(cmds.count == 1)
        #expect(cmds[0] == Data([0x11, 0x07, 0x01, 0x02, 0x03]))
    }

    // test_read_battery_state: read command [0x11, 0xCC]
    @Test func readBatteryState_readCommand_pythonVector() {
        #expect(MWSettings.ReadBatteryState().readCommand == Data([0x11, 0xCC]))
    }

    // test_battery_state_data: b'\x11\x8c\x63\x34\x10' → BatteryState(voltage: 4148, charge: 99)
    @Test func readBatteryState_parse_pythonVector() throws {
        let cmd = MWSettings.ReadBatteryState()
        let packet = Data([0x11, 0x8C, 0x63, 0x34, 0x10])
        let state = try cmd.parseSample(from: packet)
        #expect(state.charge  == 99)
        #expect(state.voltage == 4148)
    }

    // test_mac_address: b'\x11\x8b\x01\x07\x7b\x52\x8f\xc9\xe8' → "E8:C9:8F:52:7B:07"
    @Test func readMacAddress_readCommand() {
        #expect(MWSettings.ReadMacAddress().readCommand == Data([0x11, 0x8B]))
    }

    @Test func readMacAddress_parse_pythonVector() throws {
        let cmd = MWSettings.ReadMacAddress()
        let packet = Data([0x11, 0x8B, 0x01, 0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8])
        let mac = try cmd.parseSample(from: packet)
        #expect(mac == "E8:C9:8F:52:7B:07")
    }

    // test_read_current_power: read command [0x11, 0x91]
    @Test func readPowerStatus_readCommand_pythonVector() {
        #expect(MWSettings.ReadPowerStatus().readCommand == Data([0x11, 0x91]))
    }

    // test_power_status_signal notifications: [0x11, 0x11, value]
    @Test func readPowerStatus_parse() throws {
        let cmd = MWSettings.ReadPowerStatus()
        #expect(try cmd.parseSample(from: Data([0x11, 0x11, 0x00])) == 0x00)
        #expect(try cmd.parseSample(from: Data([0x11, 0x11, 0x01])) == 0x01)
    }

    // test_read_current_charge: read command [0x11, 0x92]
    @Test func readChargeStatus_readCommand_pythonVector() {
        #expect(MWSettings.ReadChargeStatus().readCommand == Data([0x11, 0x92]))
    }

    // test_charge_status_signal notifications: [0x11, 0x12, value]
    @Test func readChargeStatus_parse() throws {
        let cmd = MWSettings.ReadChargeStatus()
        #expect(try cmd.parseSample(from: Data([0x11, 0x12, 0x00])) == 0x00)
        #expect(try cmd.parseSample(from: Data([0x11, 0x12, 0x01])) == 0x01)
    }

    // --- Settings revision ≥ 6 features ---

    // SetAdvertisingInterval with adType appends a 4th byte (revision ≥ 6).
    // 417 ms / 0.625 = 667 = 0x029B, timeout = 0, adType = CONNECTABLE_UNDIRECTED (0).
    @Test func setAdvertisingInterval_rev6_appendsAdType() {
        let cmd = MWSettings.SetAdvertisingInterval(
            intervalMs: 417, timeoutSec: 0, adType: .connectableUndirected
        )
        #expect(cmd.commandData == Data([0x11, 0x02, 0x9B, 0x02, 0x00, 0x00]))
    }

    @Test func setAdvertisingInterval_rev6_directed() {
        let cmd = MWSettings.SetAdvertisingInterval(
            intervalMs: 417, timeoutSec: 0, adType: .connectableDirected
        )
        #expect(cmd.commandData == Data([0x11, 0x02, 0x9B, 0x02, 0x00, 0x01]))
    }

    // Whitelist filter mode: [0x11, 0x13, mode].
    @Test func setWhitelistFilterMode_allModes() {
        let pairs: [(MWSettings.WhitelistFilterMode, UInt8)] = [
            (.allowFromAny,              0x00),
            (.scanRequestsOnly,          0x01),
            (.connectionRequestsOnly,    0x02),
            (.scanAndConnectionRequests, 0x03),
        ]
        for (mode, raw) in pairs {
            let cmd = MWSettings.SetWhitelistFilterMode(mode)
            #expect(cmd.commandData == Data([0x11, 0x13, raw]))
        }
    }

    // BluetoothAddress parses display-form MAC into LSB-first bytes
    // (matches MblMwBtleAddress wire layout).
    @Test func bluetoothAddress_parse_reversesToLSBFirst() throws {
        let addr = try MWSettings.BluetoothAddress.parse("E8:C9:8F:52:7B:07")
        #expect(addr.type == .public)
        #expect(addr.bytesLSBFirst == [0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8])
    }

    @Test func bluetoothAddress_parse_acceptsDashSeparator() throws {
        let addr = try MWSettings.BluetoothAddress.parse("E8-C9-8F-52-7B-07")
        #expect(addr.bytesLSBFirst == [0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8])
    }

    @Test func bluetoothAddress_parse_rejectsMalformed() {
        #expect(throws: MWError.self) {
            _ = try MWSettings.BluetoothAddress.parse("not-a-mac")
        }
        #expect(throws: MWError.self) {
            _ = try MWSettings.BluetoothAddress.parse("E8:C9:8F:52:7B")       // 5 octets
        }
        #expect(throws: MWError.self) {
            _ = try MWSettings.BluetoothAddress.parse("E8:C9:8F:52:7B:ZZ")    // invalid hex
        }
    }

    @Test func bluetoothAddress_displayString_roundTrip() throws {
        let original = "E8:C9:8F:52:7B:07"
        let addr = try MWSettings.BluetoothAddress.parse(original)
        #expect(addr.displayString == original)
    }

    // AddWhitelistAddress: [0x11, 0x14, index, address_type, b0..b5 LSB-first].
    @Test func addWhitelistAddress_wireFormat() throws {
        let addr = try MWSettings.BluetoothAddress.parse("E8:C9:8F:52:7B:07")
        let cmd  = MWSettings.AddWhitelistAddress(index: 0, address: addr)
        #expect(cmd.commandData == Data([
            0x11, 0x14,
            0x00,                                     // slot index
            0x00,                                     // public address type
            0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8        // MAC LSB-first
        ]))
    }

    @Test func addWhitelistAddress_randomType() throws {
        let addr = MWSettings.BluetoothAddress(
            type: .random,
            bytesLSBFirst: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
        )
        let cmd = MWSettings.AddWhitelistAddress(index: 2, address: addr)
        #expect(cmd.commandData == Data([
            0x11, 0x14, 0x02, 0x01,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06
        ]))
    }

    // 3V regulator toggle: [0x11, 0x1C, enable].
    @Test func setThreeVoltPower_enable() {
        #expect(MWSettings.SetThreeVoltPower(true).commandData  == Data([0x11, 0x1C, 0x01]))
        #expect(MWSettings.SetThreeVoltPower(false).commandData == Data([0x11, 0x1C, 0x00]))
    }

    // Force 1M PHY: [0x11, 0x1D, enable].
    @Test func setForce1MPhy_enable() {
        #expect(MWSettings.SetForce1MPhy(true).commandData  == Data([0x11, 0x1D, 0x01]))
        #expect(MWSettings.SetForce1MPhy(false).commandData == Data([0x11, 0x1D, 0x00]))
    }
}

// MARK: - Disconnect-event source

@Suite("Event — disconnect source")
struct DisconnectEventSourceTests {

    // MWEventSource.disconnected() → module=settings (0x11), register=0x0A, dataID=0xFF.
    // Settings revision ≥ 2 required (verified at call site).
    @Test func disconnectEvent_source() {
        let src = MWEventSource.disconnected()
        #expect(src.module   == .settings)
        #expect(src.register == 0x0A)
        #expect(src.dataID   == 0xFF)
    }
}

// MARK: - BLE advertising name validation
//
// Ported from `MetaWear-Swift-Combine-SDK/Tests/MetaWearTests/NameUnitTests.swift`
// (`test_IsNameValid_AcceptsValidNames` / `test_IsNameValid_RejectsInvalidNames`).

@Suite("Settings — BLE advertising name validation")
struct DeviceNameValidationTests {

    @Test func acceptsValidNames() {
        let cases = [
            "Antidisestablishmentarian",  // 25 chars — at limit minus 1
            "MetaWear",
            "MetaWear ",
            " MetaWear",
            "_",
            "-"
        ]
        for name in cases {
            #expect(MWSettings.isNameValid(name), "expected valid: \(name)")
        }
    }

    @Test func rejectsInvalidNames() {
        let cases = [
            "Pneumonoultramicroscopicsilicovolcanoconiosis",  // > 26 chars
            "MetaWear $",        // $ not in allowed set
            "MetaWear ~",        // ~ not in allowed set
            "MetaWear —",        // em-dash (non-ASCII)
            "* MetaWear ",       // * not in allowed set
            "MetaWear ∀",        // non-ASCII unicode
            "😂",                // emoji
            ""                   // empty
        ]
        for name in cases {
            #expect(!MWSettings.isNameValid(name), "expected invalid: \(name)")
        }
    }

    @Test func rejectsExactly27Chars() {
        let name = String(repeating: "A", count: 27)
        #expect(!MWSettings.isNameValid(name))
    }

    @Test func acceptsExactly26Chars() {
        let name = String(repeating: "A", count: 26)
        #expect(MWSettings.isNameValid(name))
    }

    @Test func validatingInit_rejectsEmoji() {
        #expect(throws: MWError.self) {
            _ = try MWSettings.SetDeviceName(validating: "😂")
        }
    }

    @Test func validatingInit_rejectsOverLength() {
        let name = String(repeating: "A", count: 27)
        #expect(throws: MWError.self) {
            _ = try MWSettings.SetDeviceName(validating: name)
        }
    }

    @Test func validatingInit_acceptsValidName() throws {
        let cmd = try MWSettings.SetDeviceName(validating: "My-Device 1")
        #expect(cmd.name == "My-Device 1")
        #expect(cmd.commandData.first == 0x11)
        #expect(cmd.commandData[1] == 0x01)
    }
}

// MARK: - Helpers

/// A simple thread-safe bool for test assertions across tasks.
private final class MWAtomic<T: Sendable>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { _value = value }

    var value: T {
        lock.withLock { _value }
    }

    func set(_ newValue: T) {
        lock.withLock { _value = newValue }
    }
}

// MARK: - MetaWearDevice convenience for tests

private extension MetaWearDevice {
    func setDisconnectHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        onUnexpectedDisconnect = handler
    }
}
