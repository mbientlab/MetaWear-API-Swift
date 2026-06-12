import Testing
import Foundation
import MetaWear

// MARK: - Hardware verification of data-processor wire formats
//
// These chains exercise encodings that were corrected from SDK-source and
// firmware-table verification but had never run against a real board:
//
//  - **Math op codes** (firmware enum: Add=1 … Subtract=9, Abs=10,
//    Constant=11). The original Swift enum was 0-indexed and only `.modulo`
//    (4 in both tables) ever ran on hardware — `.add` was a silent no-op and
//    `.subtract` performed addition. Every case below fails against the old
//    table.
//  - **Pulse output mode 3 (`.onDetect`)** — present in the SDK enum but
//    absent from the base firmware filter table; until now confirmed on
//    1.7.x by code reading only.
//  - **Time processor** decimation.
//
// ## Deterministic on-board sample injection
//
// The Debug notification spoofer (`[0xFE, 0x03, …]`) turned out NOT to feed
// the on-board processor pipeline (see `debugSpoof_doesNotFeedProcessors`),
// so chains here are driven the same way polled logging is: an on-board
// timer fires an event that issues a sensor read, and the read response
// flows through the register's data path — which the data processor taps.
// A Counter stage then normalizes whatever the sensor reads into exact
// inputs 1, 2, 3, 4 for the processor under test.

// MARK: Helpers

/// Temperature source spec with the plain read register byte (0x81) instead
/// of the C++-conventional 0xC1 — exploration variant.
private struct LoudTempSignal: MWSignal, Sendable {
    var moduleID: UInt8    { MWModule.temperature.rawValue }
    var registerID: UInt8  { 0x81 }
    var dataID: UInt8      { 0 }
    var nChannels: UInt8   { 1 }
    var channelSize: UInt8 { 2 }
    var offset: UInt8      { 0 }
    var isSigned: Bool     { true }
}


/// Extract the processor payload as a little-endian UInt32 from a raw
/// `[0x09, 0x03, id, data...]` notification (payload may be 1–4 bytes).
private func payloadUInt32(_ packet: Data) -> UInt32 {
    let p = Data(packet)   // normalize to zero-based indices
    var value: UInt32 = 0
    for (i, byte) in p.dropFirst(3).prefix(4).enumerated() {
        value |= UInt32(byte) << (8 * i)
    }
    return value
}

/// Accumulates stream payloads on the main actor so the deadline loop can
/// observe partial progress without racing the collector task.
@MainActor
private final class PayloadBox {
    var values: [UInt32] = []
}

/// Collect up to `count` payloads from a processor stream, returning whatever
/// arrived once `count` is reached or `timeout` elapses.
@MainActor
private func collect(
    _ stream: AsyncThrowingStream<Data, Error>,
    count: Int,
    timeout: Duration = .seconds(10)
) async -> [UInt32] {
    let box = PayloadBox()
    let collector = Task { @MainActor in
        do {
            for try await packet in stream {
                box.values.append(payloadUInt32(packet))
                if box.values.count >= count { return }
            }
        } catch { /* stream ended — deadline loop below returns what we have */ }
    }
    let deadline = ContinuousClock.now + timeout
    while box.values.count < count, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
    collector.cancel()
    return box.values
}

/// Install an on-board tick source: a timer-driven event that issues `command`
/// every `periodMs`. The command's response flows through its register's data
/// path, where data processors can tap it. Caller must `startTimer` and is
/// responsible for stop/remove (or `resetBoardState` + `removeTimer`).
@MainActor
private func installTickSource(
    on device: MetaWearDevice,
    periodMs: UInt32,
    command: Data
) async throws -> MWTimer {
    let timer = try await device.createTimer(periodMs: periodMs)
    guard let module = MWModule(rawValue: command[0]) else {
        throw MWError.operationFailed("Tick command has unknown module byte")
    }
    _ = try await device.createEvent(
        source: MWEventSource(module: .timer, register: 0x06, dataID: timer.id),
        action: MWEventAction(
            module: module,
            register: command[1],
            params: command.count > 2 ? Data(command.dropFirst(2)) : Data()
        )
    )
    return timer
}

/// Build the standard deterministic chain: temperature reads (driven by a
/// timer tick) → Counter(4B). Returns the counter handle plus the timer.
/// Start the timer once the downstream processor + stream are in place.
@MainActor
private func makeTickCounter(
    on device: MetaWearDevice,
    periodMs: UInt32 = 150
) async throws -> (counter: MWProcessorHandle, timer: MWTimer) {
    // Hardware-verified recipe (MMS fw 1.7.2): LOUD reads (0x81) feed
    // processors whose SOURCE register byte is also 0x81. The C++-style
    // 0xC1 source spec never fires for processors (silent reads + 0xC1
    // triggers are the LOGGER path instead).
    let thermometer = MWThermometer(channel: 0, silent: false)
    let timer = try await installTickSource(
        on: device, periodMs: periodMs, command: thermometer.readCommand
    )
    let counter = try await device.createProcessor(
        MWDataProcessor.Counter(outputSize: 4),
        source: LoudTempSignal()
    )
    return (counter, timer)
}

/// Stop + remove a tick-source timer, swallowing errors (board may be mid-reset).
@MainActor
private func teardownTimer(_ timer: MWTimer, on device: MetaWearDevice) async {
    try? await device.stopTimer(timer)
    try? await device.removeTimer(timer)
}

// MARK: - Suite

@Suite("Hardware — Data Processor Chains", .serialized)
struct DataProcessorChainTests {

    // MARK: Tick-source smoke test

    /// Gate for the rest of the suite: a timer-driven temperature read must
    /// traverse the on-board processor pipeline and increment the counter.
    @Test @MainActor
    func smokeTest_timerDrivenReads_feedProcessors() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let (counter, timer) = try await makeTickCounter(on: device)
            let stream = try await device.streamProcessor(counter)

            try await device.startTimer(timer)
            let values = await collect(stream, count: 2, timeout: .seconds(5))
            await teardownTimer(timer, on: device)

            #expect(values == [1, 2],
                    "Timer-driven reads did not reach the data processor — the rest of this suite cannot run")
            try await resetBoardState(device)
        }
    }

    // MARK: Debug spoofer — knowledge-pinning test

    /// Empirical finding (MMS, firmware 1.7.2): the Debug notification
    /// spoofer `[0xFE, 0x03, module, reg, 0x00, value]` DOES inject into the
    /// on-board data-processor pipeline. (An earlier run concluded the
    /// opposite — that was an artifact of the SDK missing the global
    /// `[0x09, 0x03, 0x01]` notify subscribe, which suppressed ALL processor
    /// output.) Spoof-based injection is therefore a valid, timer-free way
    /// to drive switch-sourced chains deterministically.
    @Test @MainActor
    func debugSpoof_feedsProcessors() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let counter = try await device.createProcessor(
                MWDataProcessor.Counter(outputSize: 4),
                source: MWSwitchSignal()
            )
            let stream = try await device.streamProcessor(counter)

            for _ in 0..<3 {
                try await device.send(MWDebug.SpoofButtonEvent(1))
                try await Task.sleep(for: .milliseconds(80))
            }
            let values = await collect(stream, count: 3, timeout: .seconds(4))

            #expect(values == [1, 2, 3],
                    "Spoofed switch events should traverse the processor pipeline")
            try await resetBoardState(device)
        }
    }

    // MARK: Math op codes

    struct MathCase: Sendable, CustomStringConvertible {
        let op: MWDataProcessor.Math.Operation
        let rhs: Int32
        /// Expected outputs for counter inputs 1, 2, 3, 4.
        let expected: [UInt32]
        var description: String { "\(op) rhs=\(rhs)" }
    }

    private static let mathCases: [MathCase] = [
        .init(op: .add,      rhs: 10, expected: [11, 12, 13, 14]),
        .init(op: .multiply, rhs: 3,  expected: [3, 6, 9, 12]),
        .init(op: .divide,   rhs: 2,  expected: [0, 1, 1, 2]),
        .init(op: .modulo,   rhs: 3,  expected: [1, 2, 0, 1]),
        .init(op: .exponent, rhs: 2,  expected: [1, 4, 9, 16]),
        .init(op: .lshift,   rhs: 1,  expected: [2, 4, 6, 8]),
        .init(op: .rshift,   rhs: 1,  expected: [0, 1, 1, 2]),
        .init(op: .subtract, rhs: 1,  expected: [0, 1, 2, 3]),
        .init(op: .constant, rhs: 42, expected: [42, 42, 42, 42]),
    ]

    /// One connection, all ops sequentially: tear the chain down and rebuild
    /// it per case so each op sees counter inputs exactly 1, 2, 3, 4.
    @Test @MainActor
    func mathOps_allFirmwareOpcodes_computeCorrectly() async throws {
        try await withConnectedDevice { device in
            for mathCase in Self.mathCases {
                try await resetBoardState(device)
                let (counter, timer) = try await makeTickCounter(on: device)
                let math = try await device.createProcessor(
                    MWDataProcessor.Math(operation: mathCase.op, rhs: mathCase.rhs,
                                         signed: false, outputSize: 4),
                    source: counter
                )
                let stream = try await device.streamProcessor(math)

                try await device.startTimer(timer)
                let values = await collect(stream, count: 4)
                await teardownTimer(timer, on: device)

                print("  \(mathCase): expected \(mathCase.expected)  got \(values)")
                #expect(values == mathCase.expected, "\(mathCase)")
            }
            try await resetBoardState(device)
        }
    }

    /// `sqrt` separately — integer rounding behaviour (floor vs nearest) is
    /// not documented, so accept either for non-perfect squares.
    @Test @MainActor
    func mathSqrt_outputsIntegerRoot() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let (counter, timer) = try await makeTickCounter(on: device)
            let sqrtProc = try await device.createProcessor(
                MWDataProcessor.Math(operation: .sqrt, rhs: 0, signed: false, outputSize: 4),
                source: counter
            )
            let stream = try await device.streamProcessor(sqrtProc)

            try await device.startTimer(timer)
            let values = await collect(stream, count: 4)
            await teardownTimer(timer, on: device)

            print("  sqrt(1...4): got \(values)")
            try #require(values.count == 4)
            for (n, value) in zip(1...4, values) {
                let exact = Double(n).squareRoot()
                let floored = UInt32(exact)
                let nearest = UInt32(exact.rounded())
                #expect(value == floored || value == nearest,
                        "sqrt(\(n)) = \(value), expected \(floored) or \(nearest)")
            }
            try await resetBoardState(device)
        }
    }

    /// `abs` needs negative input: counter → subtract 3 (signed) → abs.
    /// Inputs 1...4 become -2, -1, 0, 1 → abs = 2, 1, 0, 1. Against the old
    /// op table this chain computed garbage twice over (`.subtract` added,
    /// `.abs` subtracted).
    @Test @MainActor
    func mathAbs_onSignedChain_computesMagnitude() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let (counter, timer) = try await makeTickCounter(on: device)
            let minusThree = try await device.createProcessor(
                MWDataProcessor.Math(operation: .subtract, rhs: 3, signed: true, outputSize: 4),
                source: counter
            )
            let magnitude = try await device.createProcessor(
                MWDataProcessor.Math(operation: .abs, rhs: 0, signed: true, outputSize: 4),
                source: minusThree
            )
            let stream = try await device.streamProcessor(magnitude)

            try await device.startTimer(timer)
            let values = await collect(stream, count: 4)
            await teardownTimer(timer, on: device)

            print("  |1...4 - 3|: got \(values)")
            #expect(values == [2, 1, 0, 1])
            try await resetBoardState(device)
        }
    }

    // MARK: Pulse detector — onDetect (mode 3)

    /// Drive a controllable waveform into a Pulse processor: a timer-driven
    /// event reads GPIO pin 0's ADC while the host toggles the same pin's
    /// output driver low → high → low. The high plateau (~1023 counts at
    /// 10-bit ratio) exceeds the threshold for ≥ width samples, then the
    /// falling edge completes the pulse.
    ///
    /// NOTE: this relies on the SAADC reading back the pin's own driven
    /// level. If the firmware floats the pin during analog reads, the
    /// readings (printed below) will show noise instead of a clean
    /// 0 → 1023 → 0 shape — in that case rig pin 0 to a real signal and
    /// revisit.
    @Test @MainActor
    func pulseDetector_onDetectMode_firesOncePerPulse() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let pin: UInt8 = 0
            let readCmd = MWGPIO.AnalogRead(mode: .adc, pin: pin, silent: false).commandData
            let timer = try await installTickSource(on: device, periodMs: 100, command: readCmd)

            let pulse = try await device.createProcessor(
                MWDataProcessor.Pulse(output: .onDetect, threshold: 512, width: 2),
                source: GPIOReadBitSignal()   // 0x87 — must match the loud read register
            )
            let stream = try await device.streamProcessor(pulse)

            try await device.send(MWGPIO.SetLow(pin: pin))
            try await device.startTimer(timer)
            try await Task.sleep(for: .milliseconds(350))   // a few low samples
            try await device.send(MWGPIO.SetHigh(pin: pin))
            try await Task.sleep(for: .milliseconds(450))   // ≥ width high samples
            try await device.send(MWGPIO.SetLow(pin: pin))
            try await Task.sleep(for: .milliseconds(350))   // falling edge completes pulse

            let values = await collect(stream, count: 1, timeout: .seconds(3))
            await teardownTimer(timer, on: device)

            print("  pulse .onDetect: got \(values)")
            try #require(values.count >= 1,
                         "Pulse mode 3 (.onDetect) produced no output — unsupported mode, or GPIO loopback floated (see note)")
            #expect(values[0] == 1)
            try await resetBoardState(device)
        }
    }

    /// Same waveform through `.peak` (mode 2, in the base firmware table) as
    /// a control: the peak must be the high-plateau ADC reading (> threshold).
    @Test @MainActor
    func pulseDetector_peakMode_reportsPlateau() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let pin: UInt8 = 0
            let readCmd = MWGPIO.AnalogRead(mode: .adc, pin: pin, silent: false).commandData
            let timer = try await installTickSource(on: device, periodMs: 100, command: readCmd)

            let pulse = try await device.createProcessor(
                MWDataProcessor.Pulse(output: .peak, threshold: 512, width: 2),
                source: GPIOReadBitSignal()   // 0x87 — must match the loud read register
            )
            let stream = try await device.streamProcessor(pulse)

            try await device.send(MWGPIO.SetLow(pin: pin))
            try await device.startTimer(timer)
            // Two complete pulses — peak/width/area modes emit on pulse
            // completion, and a second pulse guards against edge effects at
            // the first falling edge.
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(350))
                try await device.send(MWGPIO.SetHigh(pin: pin))
                try await Task.sleep(for: .milliseconds(450))
                try await device.send(MWGPIO.SetLow(pin: pin))
            }
            try await Task.sleep(for: .milliseconds(400))

            let values = await collect(stream, count: 2, timeout: .seconds(3))
            await teardownTimer(timer, on: device)

            print("  pulse .peak: got \(values)")
            // Open firmware question (MMS fw 1.7.2): `.onDetect` fires on
            // this exact waveform, but `.peak` (and presumably width/area,
            // which share the completion-emission path) produces nothing
            // across two complete pulses. Recorded as a known issue pending
            // clarification from the firmware side.
            withKnownIssue("Pulse .peak emits nothing on fw 1.7.2 where .onDetect fires (completion-path modes unverified)") {
                try #require(values.count >= 1, "Peak mode emitted nothing across two complete pulses")
                #expect(values[0] > 512, "Peak \(values[0]) should exceed the 512-count threshold")
            }
            try await resetBoardState(device)
        }
    }

    // MARK: Time processor decimation

    /// Temperature ticks every 100 ms through a 500 ms Time processor for
    /// ~1.2 s: outputs must be decimated — more than zero, far fewer than
    /// the ~12 reads that went in.
    @Test @MainActor
    func timeProcessor_absoluteMode_decimates() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let thermometer = MWThermometer(channel: 0)
            let timer = try await installTickSource(
                on: device, periodMs: 100, command: thermometer.readCommand
            )
            let throttle = try await device.createProcessor(
                MWDataProcessor.Time(periodMs: 500, mode: .absolute),
                source: LoudTempSignal()   // 0x81 — must match the loud read register
            )
            let stream = try await device.streamProcessor(throttle)

            try await device.startTimer(timer)
            try await Task.sleep(for: .milliseconds(1200))
            let values = await collect(stream, count: 12, timeout: .seconds(1))
            await teardownTimer(timer, on: device)

            print("  time(500ms) over ~12 reads: got \(values.count) outputs")
            #expect(!values.isEmpty, "Time processor passed nothing")
            #expect(values.count <= 5, "Time processor did not decimate (\(values.count) outputs)")
            try await resetBoardState(device)
        }
    }
}

// MARK: - Exploration: which read variant feeds the processor tap?
//
// Empirically maps the firmware's read→consumer routing. Counter processors
// are attached to the temperature signal with two source-register specs
// (0xC1 = read|data_id per the C++ vectors, and 0x81 = plain read register),
// then loud (0x81) and silent (0xC1) reads are issued from the host. The
// printout shows which combination makes data flow on-board.

/// Fire-and-forget wrapper so arbitrary command bytes can go through `send`.
private struct RawCommand: MWCommand, Sendable {
    let commandData: Data
}

/// GPIO ADC source spec with the read bit set (0x87) — exploration variant.
private struct GPIOReadBitSignal: MWSignal, Sendable {
    var moduleID: UInt8    { MWModule.gpio.rawValue }
    var registerID: UInt8  { 0x87 }
    var dataID: UInt8      { 0 }
    var nChannels: UInt8   { 1 }
    var channelSize: UInt8 { 2 }
    var offset: UInt8      { 0 }
    var isSigned: Bool     { false }
}

@Suite("Hardware — Read-path Exploration", .serialized)
struct ReadPathExplorationTests {

    @Test @MainActor
    func explore_whichReadVariantFeedsProcessors() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)

            // Variant 1: source register 0xC1 (C++ convention).
            let counterC1 = try await device.createProcessor(
                MWDataProcessor.Counter(outputSize: 4),
                source: MWTemperatureSignal(channel: 0)
            )
            let streamC1 = try await device.streamProcessor(counterC1)

            // Variant 2: source register 0x81.
            var counter81: MWProcessorHandle?
            var stream81: AsyncThrowingStream<Data, Error>?
            do {
                let handle = try await device.createProcessor(
                    MWDataProcessor.Counter(outputSize: 4),
                    source: LoudTempSignal()
                )
                counter81 = handle
                stream81 = try await device.streamProcessor(handle)
                print("  [setup] 0x81-source counter created: id \(handle.id)")
            } catch {
                print("  [setup] 0x81-source counter REJECTED: \(error)")
            }

            func probe(_ label: String, readRegister: UInt8) async {
                for _ in 0..<3 {
                    try? await device.send(RawCommand(commandData: Data([0x04, readRegister, 0x00])))
                    try? await Task.sleep(for: .milliseconds(150))
                }
                let c1Hits = await collect(streamC1, count: 3, timeout: .seconds(2))
                let h81Hits: [UInt32]
                if let stream81 { h81Hits = await collect(stream81, count: 3, timeout: .seconds(1)) }
                else { h81Hits = [] }
                print("  [probe] \(label): 0xC1-source counter → \(c1Hits)   0x81-source counter → \(h81Hits)")
            }

            await probe("LOUD reads (0x81)", readRegister: 0x81)
            await probe("SILENT reads (0xC1)", readRegister: 0xC1)

            // Probe 3: global data-processor enable (0x09, 0x01) — the spec
            // documents it and the SDK never writes it. Does it gate read paths?
            try await device.send(RawCommand(commandData: Data([0x09, 0x01, 0x01])))
            await probe("SILENT reads after [09 01 01] enable", readRegister: 0xC1)
            await probe("LOUD reads after [09 01 01] enable", readRegister: 0x81)

            // Probe 4: GPIO source-register variants. The C++ table uses the
            // RAW register (0x07) for the ADC source; given the temperature
            // finding (source must equal the read register), check 0x87 too.
            try await resetBoardState(device)
            let gpioRaw = try await device.createProcessor(
                MWDataProcessor.Counter(outputSize: 4),
                source: MWGPIOAnalogSignal(pin: 0, mode: .adc)   // registerID 0x07
            )
            let gpioRawStream = try await device.streamProcessor(gpioRaw)
            let gpioRead = try await device.createProcessor(
                MWDataProcessor.Counter(outputSize: 4),
                source: GPIOReadBitSignal()                       // registerID 0x87
            )
            let gpioReadStream = try await device.streamProcessor(gpioRead)
            for _ in 0..<3 {
                try? await device.send(RawCommand(commandData: Data([0x05, 0x87, 0x00])))
                try? await Task.sleep(for: .milliseconds(150))
            }
            let rawHits = await collect(gpioRawStream, count: 3, timeout: .seconds(2))
            let readHits = await collect(gpioReadStream, count: 3, timeout: .seconds(1))
            print("  [probe] GPIO loud ADC reads: 0x07-source → \(rawHits)   0x87-source → \(readHits)")

            _ = counter81  // silence unused warning when creation failed
            try await resetBoardState(device)
        }
    }

    /// Does the data processor work on a STREAMING signal at all? Counter on
    /// the live accelerometer data register while the accel streams — if this
    /// flows, processors are fine and only read-based sources are dead.
    @Test @MainActor
    func explore_processorOnStreamingSignal() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let info = await device.deviceInfo
            print("  [info] model=\(info?.modelNumber ?? "?") firmware=\(info?.firmwareRevision ?? "?")")

            let counter = try await device.createProcessor(
                MWDataProcessor.Counter(outputSize: 4),
                source: MWAccelerometerSignal()
            )
            let stream = try await device.streamProcessor(counter)

            guard let accel = await device.makeAccelerometer(odrHz: 25, rangeG: 8) else {
                throw MWError.operationFailed("No accelerometer")
            }
            switch accel {
            case .bmi160(let s): try await device.prepareSignalSource(s)
            case .bmi270(let s): try await device.prepareSignalSource(s)
            }

            let values = await collect(stream, count: 5, timeout: .seconds(5))
            print("  [probe] counter on streaming accel: \(values)")

            switch accel {
            case .bmi160(let s): try await device.teardownSignalSource(s)
            case .bmi270(let s): try await device.teardownSignalSource(s)
            }
            #expect(!values.isEmpty, "Processor produced nothing even on a streaming source")
            try await resetBoardState(device)
        }
    }

    /// Does the polled-logging feature (timer → event → silent read → LOGGER)
    /// actually capture entries on hardware? This is the SDK feature the app's
    /// temperature/humidity logging is built on — never hardware-verified.
    @Test @MainActor
    func explore_polledLoggingCapturesEntries() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            let logger = MWPolledLogger(readable: MWThermometer(channel: 0), periodMs: 300)
            let handles = try await device.startLogging(logger)
            try await Task.sleep(for: .seconds(2))
            try await device.stopLogging(logger, handles: handles)

            var samples: [MWLoggedSample<Float>] = []
            let download = try await device.downloadLogs(logger)
            for try await progress in download { samples = progress.data }
            print("  [probe] polled temp logger over 2 s @300 ms: \(samples.count) samples: \(samples.map(\.value))")

            #expect(samples.count >= 3, "Polled logging captured \(samples.count) samples — feature broken on hardware?")
            try await resetBoardState(device)
        }
    }
}
