import Testing
import Foundation
@testable import MetaWear

// MARK: - Shared helpers
//
// Mirrors MetaWear-SDK-Cpp/test/test_anonymous_signal.py.
// Wire format note: real MetaWear firmware does NOT echo the queried logger/
// processor ID back in the response — the response is just `[module, 0x82,
// payload...]`. The queried `id` is implicit (the loop variable in the SDK).
// These fixtures match the Python byte-strings byte-for-byte.

private func connectedDevice(
    injectLogTime tick: UInt32? = nil
) async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = MockBLETransport()
    await transport.setReadResponse(Data("MbientLab".utf8),   for: MWUUIDs.manufacturerName)
    await transport.setReadResponse(Data("MetaMotionR".utf8), for: MWUUIDs.modelNumber)
    await transport.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await transport.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await transport.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)

    let device = MetaWearDevice(identifier: UUID(), transport: transport)

    var respondedTo = Set<Data>()
    let discovery = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let cmds = await transport.writtenCommands
            for cmd in cmds {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !respondedTo.contains(cmd) else { continue }
                respondedTo.insert(cmd)

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

                let impl: UInt8 = ([0x03, 0x04, 0x0B, 0x09, 0x13, 0x19].contains(cmd[0])) ? 0x01 : 0xFF
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

// MARK: - Tranche A: queryActiveProcessors

/// Scripted responder: wires up a mock board that answers logger, processor,
/// and range queries with pre-declared byte vectors. Mirrors the Python
/// `AnonymousSignalBase.commandLogger` + `schedule_response` pattern.
private actor ScriptedResponder {
    let transport: MockBLETransport
    var loggerResponses: [UInt8: [UInt8]] = [:]   // logger_id → response payload (without header)
    var procResponses:   [UInt8: [UInt8]] = [:]
    var accelRange: UInt8 = 0x08                   // BMI160 8g
    var gyroRange:  UInt8 = 0x03                   // 250 dps
    var fusionMode: [UInt8] = [0x01, 0x0F]         // matches Python `[0x19, 0x82, 0x1, 0xf]`

    init(transport: MockBLETransport) { self.transport = transport }

    func setLoggerResponse(_ id: UInt8, payload: [UInt8]) { loggerResponses[id] = payload }
    func setProcResponse(_ id: UInt8, payload: [UInt8])   { procResponses[id] = payload }
    func setAccelRange(_ r: UInt8) { accelRange = r }
    func setGyroRange(_ r: UInt8)  { gyroRange = r }

    /// Start polling writtenCommands; inject matching responses. Returns the Task
    /// so callers can cancel it.
    func start() -> Task<Void, Never> {
        Task {
            var seen = Set<Data>()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
                let cmds = await self.transport.writtenCommands
                for cmd in cmds {
                    guard !seen.contains(cmd) else { continue }
                    guard cmd.count >= 2 else { continue }
                    seen.insert(cmd)
                    await self.respond(to: cmd)
                }
            }
        }
    }

    private func respond(to cmd: Data) async {
        // [0x0B, 0x82, id] — logger query
        // Real firmware response: [0x0B, 0x82, src_mod, src_reg, src_data_id, packed]
        // (no logger-ID echo — `id` is implicit from the query)
        if cmd.count == 3, cmd[0] == 0x0B, cmd[1] == 0x82 {
            let id = cmd[2]
            if let payload = loggerResponses[id] {
                await transport.inject(notification: Data([0x0B, 0x82] + payload), to: MWUUIDs.notify)
            }
            return
        }
        // [0x09, 0x82, id] — processor query
        // Real firmware response: [0x09, 0x82, parent_mod, parent_reg, parent_proc_id, packed, proc_type, config...]
        if cmd.count == 3, cmd[0] == 0x09, cmd[1] == 0x82 {
            let id = cmd[2]
            if let payload = procResponses[id] {
                await transport.inject(notification: Data([0x09, 0x82] + payload), to: MWUUIDs.notify)
            }
            return
        }
        // [0x03, 0x83] — accel range read
        if cmd.count == 2, cmd[0] == 0x03, cmd[1] == 0x83 {
            await transport.inject(notification: Data([0x03, 0x83, 40, accelRange]), to: MWUUIDs.notify)
            return
        }
        // [0x13, 0x83] — gyro range read
        if cmd.count == 2, cmd[0] == 0x13, cmd[1] == 0x83 {
            await transport.inject(notification: Data([0x13, 0x83, 40, gyroRange]), to: MWUUIDs.notify)
            return
        }
    }
}

@Suite("MetaWearDevice — queryActiveProcessors")
struct QueryActiveProcessorsTests {

    /// Exercises the TestActivity Python fixture: a three-stage chain
    ///   accel → RMS(proc0) → accumulate(proc1) → time(proc2)
    /// plus a buffer-state(proc3) branch. Confirms every byte-level field
    /// is parsed correctly and that `parentIsProcessor` reflects the chain.
    @Test func parsesActivityChain() async throws {
        let (device, transport) = try await connectedDevice()

        let responder = Task {
            // Python TestActivity responses. Wire format is `[0x09, 0x82,
            // parent_mod, parent_reg, parent_proc_id, packed, proc_type, config...]`
            // — no logger/processor-id echo; the SDK derives the id from its
            // own query loop variable.
            // proc 0: accel XYZ → RMS. parent_mod=0x03, parent_reg=0x04,
            //         parent_proc_id=0xFF, packed=0xA0 (offset=0, length=6), type=0x07 (RMS)
            let p0: [UInt8] = [0x09, 0x82,
                               0x03, 0x04, 0xFF, 0xA0, 0x07,
                               0xA5, 0x00, 0x00, 0x00, 0x00, 0xD0,
                               0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            // proc 1: RMS(proc0) → accumulate. parent=dataproc(0x09)/notify(0x03),
            //         parent_proc_id=0x00, packed=0x20 (offset=0, length=2), type=0x02
            let p1: [UInt8] = [0x09, 0x82,
                               0x09, 0x03, 0x00, 0x20, 0x02,
                               0x07, 0x00, 0x00, 0x00, 0x00, 0xD0,
                               0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            // proc 2: accumulate(proc1) → time. parent_proc_id=0x01, packed=0x60 (offset=0,len=4), type=0x08
            let p2: [UInt8] = [0x09, 0x82,
                               0x09, 0x03, 0x01, 0x60, 0x08,
                               0x13, 0x30, 0x75, 0x00, 0x00, 0xD0,
                               0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            // proc 3: accumulate(proc1) → buffer (type=0x0F).
            let p3: [UInt8] = [0x09, 0x82,
                               0x09, 0x03, 0x01, 0x60, 0x0F,
                               0x03, 0x00, 0x00, 0x00, 0x00, 0xD0,
                               0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            for r in [p0, p1, p2, p3] {
                try? await Task.sleep(nanoseconds: 5_000_000)
                await transport.inject(notification: Data(r), to: MWUUIDs.notify)
            }
            // Stop enumeration after id=3 by letting id=4 time out.
        }
        defer { responder.cancel() }

        let procs = try await device.queryActiveProcessors()
        #expect(procs.count == 4)

        // Proc 0 — RMS on accel XYZ
        #expect(procs[0].processorID == 0)
        #expect(procs[0].parentModule == .accelerometer)
        #expect(procs[0].parentRegister == 0x04)
        #expect(procs[0].parentIsProcessor == false)
        #expect(procs[0].chunkOffset == 0)
        #expect(procs[0].chunkLength == 6)
        #expect(procs[0].processorType == 0x07)
        #expect(procs[0].configBytes.first == 0xA5)

        // Proc 1 — accumulate of proc0
        #expect(procs[1].parentIsProcessor == true)
        #expect(procs[1].parentProcessorID == 0x00)
        #expect(procs[1].processorType == 0x02)
        #expect(procs[1].chunkLength == 2)

        // Proc 2 — time of proc1
        #expect(procs[2].parentIsProcessor == true)
        #expect(procs[2].parentProcessorID == 0x01)
        #expect(procs[2].processorType == 0x08)
        #expect(procs[2].chunkLength == 4)

        // Proc 3 — buffer of proc1
        #expect(procs[3].parentProcessorID == 0x01)
        #expect(procs[3].processorType == 0x0F)
    }

    /// Empty-graph short-circuit: first query times out → no processors.
    @Test func noProcessorsTimesOutEarly() async throws {
        let (device, _) = try await connectedDevice()
        let procs = try await device.queryActiveProcessors()
        #expect(procs.isEmpty)
    }
}

// MARK: - Tranche B: Scheme identifier builder

@Suite("MWAnonymousSignalScheme — root identifiers")
struct SchemeRootIdentifierTests {

    @Test func acceleration_packedXYZ() {
        let s = MWAnonymousSignalScheme.rootIdentifier(
            module: .accelerometer, register: 0x04,
            channel: 0xFF, chunkOffset: 0, chunkLength: 6
        )
        #expect(s == "acceleration")
    }

    @Test func acceleration_singleAxis_Z() {
        // Offset=4 → axis index 2 (Z)
        let s = MWAnonymousSignalScheme.rootIdentifier(
            module: .accelerometer, register: 0x04,
            channel: 0xFF, chunkOffset: 4, chunkLength: 2
        )
        #expect(s == "acceleration[2]")
    }

    @Test func angularVelocity_Yaxis() {
        // Matches TestGyroY: `"angular-velocity[1]"`
        let s = MWAnonymousSignalScheme.rootIdentifier(
            module: .gyro, register: 0x05,
            channel: 0xFF, chunkOffset: 2, chunkLength: 2
        )
        #expect(s == "angular-velocity[1]")
    }

    @Test func temperature_perChannel() {
        // TestTemperature: channel byte 0..3 drives the suffix.
        for c: UInt8 in 0..<4 {
            let s = MWAnonymousSignalScheme.rootIdentifier(
                module: .temperature, register: 0xC1,
                channel: c, chunkOffset: 0, chunkLength: 4
            )
            #expect(s == "temperature[\(c)]")
        }
    }

    @Test func quaternion_fromSensorFusion() {
        // Register 0x07 = quaternion data
        let s = MWAnonymousSignalScheme.rootIdentifier(
            module: .sensorFusion, register: 0x07,
            channel: 0xFF, chunkOffset: 0, chunkLength: 16
        )
        #expect(s == "quaternion")
    }

    @Test func unknownModuleReturnsNil() {
        let s = MWAnonymousSignalScheme.rootIdentifier(
            module: .haptic, register: 0x01,
            channel: 0, chunkOffset: 0, chunkLength: 0
        )
        #expect(s == nil)
    }
}

@Suite("MWAnonymousSignalScheme — processor segments")
struct SchemeProcessorSegmentTests {

    @Test func rms_simple() {
        let s = MWAnonymousSignalScheme.processorSegment(type: 0x07, id: 0, config: [0xA5, 0x07])
        #expect(s == "rms?id=0")
    }

    @Test func rss_byConfigMode() {
        let s = MWAnonymousSignalScheme.processorSegment(type: 0x07, id: 0, config: [0xA5, 0x0B])
        #expect(s == "rss?id=0")
    }

    @Test func accumulate_defaultMode() {
        let s = MWAnonymousSignalScheme.processorSegment(type: 0x02, id: 1, config: [0x00])
        #expect(s == "accumulate?id=1")
    }

    @Test func count_byConfigMode() {
        let s = MWAnonymousSignalScheme.processorSegment(type: 0x02, id: 1, config: [0x01])
        #expect(s == "count?id=1")
    }

    @Test func lowpass_vs_highpass() {
        let lp = MWAnonymousSignalScheme.processorSegment(type: 0x03, id: 2, config: [0x00, 0x00])
        let hp = MWAnonymousSignalScheme.processorSegment(type: 0x03, id: 2, config: [0x00, 0x01])
        #expect(lp == "low-pass?id=2")
        #expect(hp == "high-pass?id=2")
    }

    @Test func coversFullTypeTable() {
        let expected: [UInt8: String] = [
            0x01: "passthrough",
            0x06: "comparison",
            0x08: "time",
            0x09: "math",
            0x0A: "delay",
            0x0B: "pulse",
            0x0C: "differential",
            0x0D: "threshold",
            0x0F: "buffer",
            0x10: "packer",
            0x11: "account",
            0x1B: "fuser",
        ]
        for (type, name) in expected {
            let seg = MWAnonymousSignalScheme.processorSegment(type: type, id: 0, config: [])
            #expect(seg == "\(name)?id=0", "Expected \(name)?id=0 for type 0x\(String(type, radix: 16))")
        }
    }

    @Test func unknownTypeReturnsNil() {
        let s = MWAnonymousSignalScheme.processorSegment(type: 0x7F, id: 0, config: [])
        #expect(s == nil)
    }
}

@Suite("MWAnonymousSignalScheme — full chain composition")
struct SchemeCompositionTests {

    /// Mirrors TestActivity signal[0]:
    /// `"acceleration:rms?id=0:accumulate?id=1:time?id=2"`
    @Test func activityFullChain() {
        let id = MWAnonymousSignalScheme.compose(
            root: "acceleration",
            chain: [
                (type: 0x07, id: 0, config: [0xA5, 0x07]),  // RMS
                (type: 0x02, id: 1, config: [0x00]),         // accumulate
                (type: 0x08, id: 2, config: [])              // time
            ]
        )
        #expect(id == "acceleration:rms?id=0:accumulate?id=1:time?id=2")
    }

    /// TestActivity signal[1] — same chain but the terminal logger
    /// captures the buffer's *state* register, not its data output:
    /// `"acceleration:rms?id=0:accumulate?id=1:buffer-state?id=3"`
    @Test func activityBufferStateChain() {
        let id = MWAnonymousSignalScheme.compose(
            root: "acceleration",
            chain: [
                (type: 0x07, id: 0, config: [0xA5, 0x07]),
                (type: 0x02, id: 1, config: [0x00]),
                (type: 0x0F, id: 3, config: [0x03])  // buffer
            ],
            captureStateOfTerminalBuffer: true
        )
        #expect(id == "acceleration:rms?id=0:accumulate?id=1:buffer-state?id=3")
    }

    /// TestQuaternionLimiter: `"quaternion:time?id=0"`
    @Test func quaternionLimiter() {
        let id = MWAnonymousSignalScheme.compose(
            root: "quaternion",
            chain: [(type: 0x08, id: 0, config: [])]
        )
        #expect(id == "quaternion:time?id=0")
    }

    /// TestFuser: `"acceleration:fuser?id=1"`
    @Test func fuser() {
        let id = MWAnonymousSignalScheme.compose(
            root: "acceleration",
            chain: [(type: 0x1B, id: 1, config: [0x01, 0x00])]
        )
        #expect(id == "acceleration:fuser?id=1")
    }

    /// Flat root (no processors) → no trailing colon.
    @Test func flatRoot() {
        let id = MWAnonymousSignalScheme.compose(root: "acceleration", chain: [])
        #expect(id == "acceleration")
    }

    /// Unknown processor type short-circuits the whole composition.
    @Test func unknownTypeAborts() {
        let id = MWAnonymousSignalScheme.compose(
            root: "acceleration",
            chain: [(type: 0xFF, id: 0, config: [])]
        )
        #expect(id == nil)
    }
}

// MARK: - Tranche D: Python test-suite port
//
// Port of test_anonymous_signal.py. Each `@Suite` below mirrors one Python class.
// Byte vectors for processor query responses match the Python reference
// verbatim — the firmware does not echo the query ID, so the response lines up
// directly with the documented `[parent_mod, parent_reg, parent_proc_id,
// packed, proc_type, config...]` layout.

private func anonSetup(
    accelRange: UInt8 = 0x08,
    gyroRange: UInt8 = 0x03
) async throws -> (MetaWearDevice, ScriptedResponder, Task<Void, Never>) {
    let (device, transport) = try await connectedDevice()
    let responder = ScriptedResponder(transport: transport)
    await responder.setAccelRange(accelRange)
    await responder.setGyroRange(gyroRange)
    let task = await responder.start()
    return (device, responder, task)
}

@Suite("Anonymous — TestAcceleration")
struct TestAccelerationAnon {

    @Test func sync_loggers_and_identifier() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // Logger 0: accel packed=0x60 (offset=0, length=4)
        // Logger 1: accel packed=0x24 (offset=4, length=2) — completes XYZ split
        await responder.setLoggerResponse(0, payload: [0x03, 0x04, 0xFF, 0x60])
        await responder.setLoggerResponse(1, payload: [0x03, 0x04, 0xFF, 0x24])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 1)
        #expect(signals.first?.identifier == "acceleration")
        #expect(signals.first?.loggerIDs == [0, 1])
    }

    @Test func decode_xyz() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }
        await responder.setLoggerResponse(0, payload: [0x03, 0x04, 0xFF, 0x60])
        await responder.setLoggerResponse(1, payload: [0x03, 0x04, 0xFF, 0x24])

        let signals = try await device.createAnonymousDataSignals()
        let sig = try #require(signals.first)

        // int16 values: x=0x00F5=245, y=0x013D=317, z=0x0FDD=4061
        // Scale 4096 → x=0.0598, y=0.0774, z=0.9915
        let payload = Data([0xF5, 0x00, 0x3D, 0x01, 0xDD, 0x0F])
        let out = try sig.decode(payload)
        #expect(out.count == 1)
        if case let .cartesian(v) = out[0] {
            #expect(abs(v.x - 0.060) < 0.001)
            #expect(abs(v.y - 0.077) < 0.001)
            #expect(abs(v.z - 0.991) < 0.001)
        } else {
            Issue.record("expected .cartesian, got \(out[0])")
        }
    }
}

@Suite("Anonymous — TestGyroY")
struct TestGyroYAnon {

    @Test func sync_and_identifier() async throws {
        // Python uses gyr_range=0x03 (250 dps → scale 131.2)
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // Single logger on gyro Y axis: packed=0x22 (offset=2, length=2)
        await responder.setLoggerResponse(0, payload: [0x13, 0x05, 0xFF, 0x22])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 1)
        #expect(signals.first?.identifier == "angular-velocity[1]")
    }

    @Test func decode_scalar() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }
        await responder.setLoggerResponse(0, payload: [0x13, 0x05, 0xFF, 0x22])

        let signals = try await device.createAnonymousDataSignals()
        let sig = try #require(signals.first)

        // int16 value -7 → -7 / 131.2 ≈ -0.0534
        let out = try sig.decode(Data([0xF9, 0xFF]))
        #expect(out.count == 1)
        if case let .scalar(v) = out[0] {
            #expect(abs(v - (-0.053)) < 0.001)
        } else {
            Issue.record("expected .scalar, got \(out[0])")
        }
    }
}

@Suite("Anonymous — TestSplitImu")
struct TestSplitImuAnon {

    @Test func two_signals_accel_and_gyro() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // Python fixture: 4 loggers total — accel(id=0,2), gyro(id=1,3).
        await responder.setLoggerResponse(0, payload: [0x03, 0x04, 0xFF, 0x60])
        await responder.setLoggerResponse(1, payload: [0x13, 0x05, 0xFF, 0x60])
        await responder.setLoggerResponse(2, payload: [0x03, 0x04, 0xFF, 0x24])
        await responder.setLoggerResponse(3, payload: [0x13, 0x05, 0xFF, 0x24])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 2)
        let ids = signals.map(\.identifier)
        #expect(ids.contains("acceleration"))
        #expect(ids.contains("angular-velocity"))
    }
}

@Suite("Anonymous — TestActivity")
struct TestActivityAnon {

    @Test func full_chain_identifiers() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // Two loggers on data-processor output:
        //   logger 0 — proc 2 data (time terminus)   register 0x03, channel=0x02
        //   logger 1 — proc 3 state (buffer-state)   register 0xC4, channel=0x03
        await responder.setLoggerResponse(0, payload: [0x09, 0x03, 0x02, 0x60])
        await responder.setLoggerResponse(1, payload: [0x09, 0xC4, 0x03, 0x60])

        // Processor chain: accel → RMS(0) → accumulate(1) → time(2), buffer(3)
        await responder.setProcResponse(0, payload: [0x03, 0x04, 0xFF, 0xA0, 0x07,
                                                      0xA5, 0x00, 0x00, 0x00, 0x00, 0xD0,
                                                      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        await responder.setProcResponse(1, payload: [0x09, 0x03, 0x00, 0x20, 0x02,
                                                      0x07, 0x00, 0x00, 0x00, 0x00, 0xD0,
                                                      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        await responder.setProcResponse(2, payload: [0x09, 0x03, 0x01, 0x60, 0x08,
                                                      0x13, 0x30, 0x75, 0x00, 0x00, 0xD0,
                                                      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        await responder.setProcResponse(3, payload: [0x09, 0x03, 0x01, 0x60, 0x0F,
                                                      0x03, 0x00, 0x00, 0x00, 0x00, 0xD0,
                                                      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 2)
        let ids = signals.map(\.identifier)
        #expect(ids.contains("acceleration:rms?id=0:accumulate?id=1:time?id=2"))
        #expect(ids.contains("acceleration:rms?id=0:accumulate?id=1:buffer-state?id=3"))
    }
}

@Suite("Anonymous — TestQuaternionLimiter")
struct TestQuaternionLimiterAnon {

    @Test func identifier() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // Four loggers capturing the quaternion-time output, one per 4-byte chunk.
        // Each targets proc 0's notify register; channels all = 0x00.
        // Packed: offset=0/4/8/12, length=4 → 0x60, 0x64, 0x68, 0x6C.
        // Use distinct channels so each logger becomes its own 4-byte signal chunk.
        for (id, offset) in [(0, UInt8(0x60)), (1, 0x64), (2, 0x68), (3, 0x6C)] {
            await responder.setLoggerResponse(UInt8(id),
                payload: [0x09, 0x03, 0x00, offset])
        }

        // Proc 0: quaternion → time.
        // parent_mod=0x19 (sensorFusion), parent_reg=0x07 (quaternion),
        // parent_proc_id=0xFF, packed=0xE0 (offset=0, length=16), type=0x08 (time)
        await responder.setProcResponse(0, payload: [0x19, 0x07, 0xFF, 0xE0, 0x08,
                                                      0x17, 0x14, 0x00, 0x00, 0x00, 0xD0,
                                                      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 1)
        #expect(signals.first?.identifier == "quaternion:time?id=0")
    }
}

@Suite("Anonymous — TestMultipleLoggers")
struct TestMultipleLoggersAnon {

    @Test func two_signals_split_gyro() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // Python fixture: three loggers on gyro.
        // id 0: gyro packed=0x60 (offset=0, length=4) — X+Y chunk
        // id 1: gyro packed=0x24 (offset=4, length=2) — Z chunk, completes XYZ with id 0
        // id 2: gyro packed=0x22 (offset=2, length=2) — single Y-axis signal
        await responder.setLoggerResponse(0, payload: [0x13, 0x05, 0xFF, 0x60])
        await responder.setLoggerResponse(1, payload: [0x13, 0x05, 0xFF, 0x24])
        await responder.setLoggerResponse(2, payload: [0x13, 0x05, 0xFF, 0x22])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 2)
        let ids = signals.map(\.identifier)
        #expect(ids.contains("angular-velocity"))
        #expect(ids.contains("angular-velocity[1]"))
    }
}

@Suite("Anonymous — TestTemperature")
struct TestTemperatureAnon {

    @Test func four_channel_identifiers() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }

        // One logger per temperature channel (0..3).
        // packed=0x20 → offset=0, length=2 (sample is 2 bytes).
        for c: UInt8 in 0..<4 {
            await responder.setLoggerResponse(c, payload: [0x04, 0xC1, c, 0x20])
        }

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 4)
        for c in 0..<4 {
            #expect(signals.contains(where: { $0.identifier == "temperature[\(c)]" }))
        }
    }

    @Test func decode_samples() async throws {
        let (device, responder, task) = try await anonSetup()
        defer { task.cancel() }
        for c: UInt8 in 0..<4 {
            await responder.setLoggerResponse(c, payload: [0x04, 0xC1, c, 0x20])
        }

        let signals = try await device.createAnonymousDataSignals()
        // Temperature scale = 8 LSB/°C. Raw 258 → 32.25°C.
        let sig = try #require(signals.first(where: { $0.identifier == "temperature[0]" }))
        let out = try sig.decode(Data([0x02, 0x01]))   // 258
        if case let .scalar(v) = out[0] {
            #expect(abs(v - 32.25) < 0.001)
        } else {
            Issue.record("expected .scalar, got \(out[0])")
        }
    }
}

@Suite("Anonymous — TestFuser")
struct TestFuserAnon {

    @Test func identifier_and_chain() async throws {
        let (device, responder, task) = try await anonSetup(accelRange: 0x03, gyroRange: 0x04)
        defer { task.cancel() }

        // Three loggers on fuser output (proc 1), 4-byte chunks covering the 12-byte fused sample.
        for (id, offset) in [(0, UInt8(0x60)), (1, 0x64), (2, 0x68)] {
            await responder.setLoggerResponse(UInt8(id),
                payload: [0x09, 0x03, 0x01, offset])
        }

        // Proc 0: gyro → RSS (or RMS)
        await responder.setProcResponse(0, payload: [0x13, 0x05, 0xFF, 0xA0, 0x0F,
                                                      0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
                                                      0x00, 0x00, 0x00, 0x00, 0x00, 0xE9, 0xFF])
        // Proc 1: accel → fuser
        await responder.setProcResponse(1, payload: [0x03, 0x04, 0xFF, 0xA0, 0x1B,
                                                      0x01, 0x00, 0x01, 0x02, 0x03, 0x04,
                                                      0x00, 0x00, 0x00, 0x00, 0x00, 0xE9, 0xFF])

        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.count == 1)
        #expect(signals.first?.identifier == "acceleration:fuser?id=1")
    }
}

@Suite("Anonymous — TestTimeout")
struct TestTimeoutAnon {

    @Test func logger_query_timeout_returns_empty() async throws {
        // No scripted responses at all — every logger query times out.
        // Per the Swift implementation, timeout in queryActiveLoggers stops
        // iteration and returns an empty list, so createAnonymousDataSignals
        // returns []. (The Python test asserts the C-style STATUS_ERROR_TIMEOUT
        // sentinel, which the Swift API doesn't surface — empty list is the
        // idiomatic equivalent since nothing was recovered.)
        let (device, _, task) = try await anonSetup()
        defer { task.cancel() }
        let signals = try await device.createAnonymousDataSignals()
        #expect(signals.isEmpty)
    }
}
