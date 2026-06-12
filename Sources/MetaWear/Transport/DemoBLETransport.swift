@preconcurrency import CoreBluetooth
import Foundation

/// A protocol-level MetaWear emulator for demos, SwiftUI previews, simulator
/// runs, and App Store screenshots — no hardware, no Bluetooth.
///
/// Behaves like a connected MetaMotion S on firmware 1.7.3: it answers module
/// discovery, Device Information reads, battery/MAC/log reads, streams
/// synthetic-but-plausible sensor waveforms when sensors are configured and
/// started (including packed registers and every sensor-fusion output), and
/// emulates the logging round trip (trigger allocation, LOG_LENGTH growth
/// while "recording", paged readout with progress).
///
/// Usage:
/// ```swift
/// let device = MetaWearDevice(identifier: DemoBLETransport.deviceIdentifier,
///                             transport: DemoBLETransport())
/// try await device.connect()   // fully functional from here
/// ```
public actor DemoBLETransport: BLETransport {

    /// Stable identifier so app-side code can recognise the demo device.
    public static let deviceIdentifier = UUID(uuidString: "DE300000-0000-4000-8000-DE300000DE30")!

    public init() {}

    // MARK: - State

    private var notifyContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var connected = false

    /// Registers the host subscribed to via `[module, register, 0x01]`.
    private var subscriptions: Set<ModuleRegister> = []
    /// Modules whose start command has been received.
    private var runningModules: Set<UInt8> = []
    /// One emitter task per running module.
    private var emitters: [UInt8: Task<Void, Never>] = [:]

    /// Reference instant for waveform phase.
    private let epoch = ContinuousClock.now

    // Sensor configs (parsed from config writes; defaults match the app's).
    private var accelScale: Float = 4096      // ±8 g
    private var gyroScale: Float = 16.4       // ±2000 dps

    // Logging emulation.
    private struct DemoLogger { let module: UInt8; let register: UInt8; let index: UInt8; let packed: UInt8 }
    private var loggers: [UInt8: DemoLogger] = [:]
    private var nextLoggerID: UInt8 = 0
    private var loggingEnabled = false
    private var loggingStarted: ContinuousClock.Instant?
    private var storedEntryCount: UInt32 = 0
    private var nextTimerID: UInt8 = 0
    private var nextEventID: UInt8 = 0
    private var nextMacroID: UInt8 = 0

    private struct ModuleRegister: Hashable {
        let module: UInt8
        let register: UInt8
    }

    // MARK: - BLETransport

    public func scan(for services: [CBUUID]?) -> AsyncStream<ScanResult> {
        AsyncStream { _ in }   // demo devices are injected, not discovered
    }

    public func connect(to identifier: UUID) async throws {
        connected = true
    }

    public func disconnect() async throws {
        connected = false
        for task in emitters.values { task.cancel() }
        emitters.removeAll()
        runningModules.removeAll()
        subscriptions.removeAll()
        notifyContinuation?.finish()
        notifyContinuation = nil
    }

    public func readRSSI() async throws -> Int {
        -52 - Int.random(in: 0...6)
    }

    public func read(from characteristic: CBUUID) async throws -> Data {
        switch characteristic {
        case MWUUIDs.manufacturerName: return Data("MbientLab Inc".utf8)
        case MWUUIDs.modelNumber:      return Data("8".utf8)            // MetaMotion S
        case MWUUIDs.serialNumber:     return Data("DEMO01".utf8)
        case MWUUIDs.firmwareRevision: return Data("1.7.3".utf8)
        case MWUUIDs.hardwareRevision: return Data("0.4".utf8)
        default:                       return Data()
        }
    }

    public func notifications(from characteristic: CBUUID) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        notifyContinuation = continuation
        return stream
    }

    public func write(_ data: Data, to characteristic: CBUUID, type: CBCharacteristicWriteType) async throws {
        guard data.count >= 2 else { return }
        handle(command: Data(data))
    }

    // MARK: - Command handling

    private func emit(_ bytes: [UInt8]) {
        notifyContinuation?.yield(Data(bytes))
    }

    private func handle(command: Data) {
        let module = command[0]
        let register = command[1]
        let payload = [UInt8](command.dropFirst(2))

        // One-shot reads (bit 7).
        if register & 0x80 != 0 {
            handleRead(module: module, register: register, payload: payload)
            return
        }

        switch (module, register) {
        // ---- Per-register notify subscribe ([module, register, 0/1]) ----
        case (_, _) where payload.count == 1 && (payload[0] == 0 || payload[0] == 1)
            && isSubscribableRegister(module: module, register: register):
            let key = ModuleRegister(module: module, register: register)
            if payload[0] == 1 { subscriptions.insert(key) } else { subscriptions.remove(key) }

        // ---- Sensor configs ----
        case (0x03, 0x03) where payload.count >= 2:   // accel ODR/range (BMI270: 0-based)
            accelScale = Float(16384 >> min(Int(payload[1] & 0x3), 3))
        case (0x13, 0x03) where payload.count >= 2:   // gyro ODR/range
            let table: [Float] = [16.4, 32.8, 65.6, 131.2, 262.4]
            gyroScale = table[min(Int(payload[1] & 0x7), 4)]

        // ---- Logging ----
        case (0x0B, 0x01):
            let enable = payload.first == 1
            if enable && !loggingEnabled { loggingStarted = .now }
            if !enable && loggingEnabled {
                storedEntryCount = currentEntryCount()
                loggingStarted = nil
            }
            loggingEnabled = enable
        case (0x0B, 0x02) where payload.count >= 4:   // add trigger
            let id = nextLoggerID
            nextLoggerID += 1
            loggers[id] = DemoLogger(module: payload[0], register: payload[1],
                                     index: payload[2], packed: payload[3])
            emit([0x0B, 0x02, id])
        case (0x0B, 0x06) where payload.count >= 4:   // readout
            let requested = UInt32(payload[0]) | (UInt32(payload[1]) << 8)
                | (UInt32(payload[2]) << 16) | (UInt32(payload[3]) << 24)
            streamLogReadout(count: min(requested, currentEntryCount()))
        case (0x0B, 0x09), (0x0B, 0x0A):              // drop entries / remove triggers
            storedEntryCount = 0
            loggingStarted = loggingEnabled ? .now : nil
            if register == 0x0A { loggers.removeAll(); nextLoggerID = 0 }

        // ---- Timer / Event / Macro allocation ----
        case (0x0C, 0x02):
            emit([0x0C, 0x02, nextTimerID]); nextTimerID += 1
        case (0x0A, 0x02):
            emit([0x0A, 0x02, nextEventID]); nextEventID += 1
        case (0x0F, 0x02):
            emit([0x0F, 0x02, nextMacroID]); nextMacroID += 1

        // ---- Module starts/stops ----
        case (0x03, 0x01), (0x13, 0x01), (0x15, 0x01), (0x19, 0x01):
            payload.first == 1 ? startEmitter(for: module) : stopEmitter(for: module)
        case (0x12, 0x04):                            // barometer cyclic [enable, altitude]
            payload.first == 1 ? startEmitter(for: module) : stopEmitter(for: module)
        case (0x14, 0x01):                            // ambient light enable
            payload.first == 1 ? startEmitter(for: module) : stopEmitter(for: module)

        default:
            break   // LED, haptic, settings writes, interrupt enables: fire-and-forget
        }
    }

    /// Data registers the host subscribes to with the 1-byte enable write.
    /// Excludes registers whose 1-byte payload means something else (module
    /// starts, logging enable, …) — those are matched explicitly above.
    private func isSubscribableRegister(module: UInt8, register: UInt8) -> Bool {
        switch (module, register) {
        case (0x03, 0x04), (0x03, 0x05),               // accel data / packed
             (0x13, 0x04), (0x13, 0x05),               // gyro data / packed (BMI270)
             (0x13, 0x07),                              // gyro packed (BMI160)
             (0x15, 0x05), (0x15, 0x09),               // mag data / packed
             (0x12, 0x01), (0x12, 0x02),               // pressure / altitude
             (0x14, 0x03),                              // illuminance
             (0x19, 0x04...0x0A),                       // fusion outputs
             (0x01, 0x01),                              // switch
             (0x09, 0x03),                              // processor notify
             (0x0B, 0x07), (0x0B, 0x08), (0x0B, 0x0D): // logging readout channels
            return true
        default:
            return false
        }
    }

    // MARK: - One-shot reads

    private func handleRead(module: UInt8, register: UInt8, payload: [UInt8]) {
        let reg = register & 0x3F
        switch (module, reg) {
        case (_, 0x00):
            emitModuleInfo(module: module, readRegister: register)
        case (0x11, 0x0C):   // battery: 87 %, 4.08 V
            emit([0x11, register, 87, 0xF0, 0x0F])
        case (0x11, 0x0B):   // MAC (7-byte form: type 0x01 + LE address)
            emit([0x11, register, 0x01, 0x01, 0xE0, 0x0D, 0x0E, 0x3D, 0xDE])
        case (0x0B, 0x04):   // logging time: tick + reset uid
            let tick = UInt32(elapsed() * 1000.0 / 1.46484375)
            emit([0x0B, register] + le32(tick) + [0x01])
        case (0x0B, 0x05):   // log length
            emit([0x0B, register] + le32(currentEntryCount()))
        case (0x0B, 0x02):   // trigger slot query
            let id = payload.first ?? 0xFF
            if let logger = loggers[id] {
                emit([0x0B, register, logger.module, logger.register, logger.index, logger.packed])
            } else {
                emit([0x0B, register, 0xFF, 0xFF, 0xFF, 0xFF])
            }
        case (0x09, 0x02):   // processor slot query: none installed
            emit([0x09, register, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        case (0x04, 0x01):   // temperature read (loud or silent): 22.5 °C wobble
            let channel = payload.first ?? 0
            let celsius = 22.5 + 0.4 * sin(elapsed() * 0.4)
            let raw = Int16(celsius * 8)
            emit([0x04, register, channel] + le16(UInt16(bitPattern: raw)))
        case (0x12, 0x01):   // barometer pressure one-shot
            emit([0x12, register] + le32(pressureRaw()))
        case (0x14, 0x03):   // ambient light one-shot (milli-lux)
            let milliLux = UInt32((320.0 + 90.0 * sin(elapsed() * 0.5)) * 1000)
            emit([0x14, register] + le32(milliLux))
        case (0x19, 0x0B):   // fusion calibration state: all high
            emit([0x19, register, 3, 3, 3])
        default:
            break   // unanswered reads time out — mirrors absent registers
        }
    }

    private func emitModuleInfo(module: UInt8, readRegister: UInt8) {
        // MetaMotion S module map (implementation, revision, extra…).
        let info: [UInt8: [UInt8]] = [
            0x01: [0, 0], 0x02: [0, 1, 3], 0x03: [4, 0], 0x04: [1, 0, 0, 3, 1, 2],
            0x05: [0, 2, 3, 3], 0x07: [0, 0], 0x08: [0, 0], 0x09: [0, 3, 0x1C],
            0x0A: [0, 0, 0x1C], 0x0B: [0, 3, 0x08] + le32(0x0400_0000) + [0x04, 0x00],
            0x0C: [0, 0, 8], 0x0D: [0, 1], 0x0F: [0, 2], 0x11: [0, 10, 0x03, 0x00],
            0x12: [0, 0], 0x13: [1, 0], 0x14: [0, 0], 0x15: [0, 2],
            0x19: [0, 3, 0, 0, 0, 0, 0, 0, 0, 0], 0xFE: [0, 6],
        ]
        if let extra = info[module] {
            emit([module, readRegister] + extra)
        } else {
            emit([module, readRegister])   // absent module: empty info
        }
    }

    // MARK: - Streaming emitters

    private func startEmitter(for module: UInt8) {
        guard runningModules.insert(module).inserted else { return }
        emitters[module] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))   // 25 Hz
                guard let self else { return }
                await self.emitSamples(for: module)
            }
        }
    }

    private func stopEmitter(for module: UInt8) {
        runningModules.remove(module)
        emitters[module]?.cancel()
        emitters[module] = nil
    }

    private func emitSamples(for module: UInt8) {
        let t = elapsed()
        switch module {
        case 0x03: emitCartesian(module: 0x03, dataReg: 0x04, packedReg: 0x05, sample: accelRaw(t))
        case 0x13: emitCartesian(module: 0x13, dataReg: 0x04, packedReg: 0x05, sample: gyroRaw(t))
        case 0x15: emitCartesian(module: 0x15, dataReg: 0x05, packedReg: 0x09, sample: magRaw(t))
        case 0x12:
            if subscriptions.contains(.init(module: 0x12, register: 0x01)) {
                emit([0x12, 0x01] + le32(pressureRaw()))
            }
            if subscriptions.contains(.init(module: 0x12, register: 0x02)) {
                let altitude = Int32((112.0 + 2.0 * sin(t * 0.2)) * 256)
                emit([0x12, 0x02] + le32(UInt32(bitPattern: altitude)))
            }
        case 0x14:
            if subscriptions.contains(.init(module: 0x14, register: 0x03)) {
                let milliLux = UInt32((320.0 + 90.0 * sin(t * 0.5)) * 1000)
                emit([0x14, 0x03] + le32(milliLux))
            }
        case 0x19: emitFusion(t)
        default: break
        }
    }

    private func emitCartesian(module: UInt8, dataReg: UInt8, packedReg: UInt8, sample: (Int16, Int16, Int16)) {
        let bytes = le16(UInt16(bitPattern: sample.0)) + le16(UInt16(bitPattern: sample.1)) + le16(UInt16(bitPattern: sample.2))
        if subscriptions.contains(.init(module: module, register: packedReg)) {
            emit([module, packedReg] + bytes + bytes + bytes)   // 3 identical-ish samples
        } else if subscriptions.contains(.init(module: module, register: dataReg)) {
            emit([module, dataReg] + bytes)
        }
    }

    private func emitFusion(_ t: Double) {
        let heading = (t * 24).truncatingRemainder(dividingBy: 360)
        let pitch = 18 * sin(t * 0.6)
        let roll = 12 * cos(t * 0.45)

        if subscriptions.contains(.init(module: 0x19, register: 0x07)) {
            // Quaternion from slowly-precessing Euler angles.
            let (h, p, r) = (heading * .pi / 180 / 2, pitch * .pi / 180 / 2, roll * .pi / 180 / 2)
            let w = Float(cos(h) * cos(p) * cos(r) + sin(h) * sin(p) * sin(r))
            let x = Float(cos(h) * sin(p) * cos(r) + sin(h) * cos(p) * sin(r))
            let y = Float(sin(h) * cos(p) * cos(r) - cos(h) * sin(p) * sin(r))
            let z = Float(cos(h) * cos(p) * sin(r) - sin(h) * sin(p) * cos(r))
            emit([0x19, 0x07] + leFloat(w) + leFloat(x) + leFloat(y) + leFloat(z))
        }
        if subscriptions.contains(.init(module: 0x19, register: 0x08)) {
            emit([0x19, 0x08] + leFloat(Float(heading)) + leFloat(Float(pitch)) + leFloat(Float(roll)) + leFloat(Float(heading)))
        }
        if subscriptions.contains(.init(module: 0x19, register: 0x09)) {
            let g = 9.80665
            emit([0x19, 0x09] + leFloat(Float(g * sin(pitch * .pi / 180))) + leFloat(Float(-g * sin(roll * .pi / 180))) + leFloat(Float(g * 0.98)))
        }
        if subscriptions.contains(.init(module: 0x19, register: 0x0A)) {
            emit([0x19, 0x0A] + leFloat(Float(0.4 * sin(t * 3))) + leFloat(Float(0.3 * cos(t * 2.2))) + leFloat(Float(0.2 * sin(t * 1.7))))
        }
        for reg: UInt8 in 0x04...0x06 where subscriptions.contains(.init(module: 0x19, register: reg)) {
            let scale: Float = reg == 0x04 ? 1000 : 1     // corrected acc in mg
            emit([0x19, reg]
                 + leFloat(Float(0.05 * sin(t)) * scale)
                 + leFloat(Float(0.04 * cos(t * 0.8)) * scale)
                 + leFloat((reg == 0x04 ? Float(1.0) : Float(0.3)) * scale)
                 + [3])                                    // accuracy: high
        }
    }

    // MARK: - Logging readout emulation

    private func currentEntryCount() -> UInt32 {
        guard loggingEnabled, let started = loggingStarted else { return storedEntryCount }
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        // 25 samples/s × 2 flash entries per accel sample (the common case).
        return storedEntryCount + UInt32(seconds * 50)
    }

    /// Emit a paged readout: paired 9-byte entries, periodic progress, a page
    /// complete at the end, then progress 0.
    private func streamLogReadout(count: UInt32) {
        let toSend = min(count, 4000)
        Task { await self.performLogReadout(count: toSend) }
    }

    private func performLogReadout(count: UInt32) async {
        let accelLoggers = loggers.filter { $0.value.module == 0x03 }.keys.sorted()
        let tempLoggers = loggers.filter { $0.value.module == 0x04 }.keys.sorted()
        var remaining = count
        var tick: UInt32 = 1000
        var sampleIndex = 0
        while remaining > 0 {
            let t = Double(sampleIndex) / 25.0
            let packet: [UInt8]
            if accelLoggers.count >= 2 {
                let s = accelRaw(t)
                let xy = le16(UInt16(bitPattern: s.0)) + le16(UInt16(bitPattern: s.1))
                let zp = le16(UInt16(bitPattern: s.2)) + [0, 0]
                packet = [0x0B, 0x07, accelLoggers[0]] + le32(tick) + xy
                       + [accelLoggers[1]] + le32(tick) + zp
                remaining = remaining >= 2 ? remaining - 2 : 0
            } else if let tempID = tempLoggers.first {
                let celsius = 22.5 + 0.4 * sin(t * 0.4)
                let raw = le16(UInt16(bitPattern: Int16(celsius * 8))) + [0, 0]
                packet = [0x0B, 0x07, tempID] + le32(tick) + raw
                remaining -= 1
            } else {
                break
            }
            emit(packet)
            tick += UInt32(1.0 / 25.0 * 1000.0 / 1.46484375)
            sampleIndex += 1
            if sampleIndex % 40 == 0 {
                emit([0x0B, 0x08] + le32(remaining))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        emit([0x0B, 0x0D])                 // page complete
        emit([0x0B, 0x08] + le32(0))       // final progress
        storedEntryCount = 0
        if loggingEnabled { loggingStarted = .now }
    }

    // MARK: - Waveforms

    private func elapsed() -> Double {
        let parts = (ContinuousClock.now - epoch).components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    private func accelRaw(_ t: Double) -> (Int16, Int16, Int16) {
        let x = 0.08 * sin(t * 1.3)
        let y = 0.06 * cos(t * 0.9)
        let z = 1.0 + 0.02 * sin(t * 2.1)
        return (Int16(x * Double(accelScale)), Int16(y * Double(accelScale)), Int16(z * Double(accelScale)))
    }

    private func gyroRaw(_ t: Double) -> (Int16, Int16, Int16) {
        let x = 40.0 * sin(t * 0.8)
        let y = 25.0 * cos(t * 0.6)
        let z = 60.0 * sin(t * 0.3)
        return (Int16(x * Double(gyroScale)), Int16(y * Double(gyroScale)), Int16(z * Double(gyroScale)))
    }

    private func magRaw(_ t: Double) -> (Int16, Int16, Int16) {
        // µT × 16 LSB; slow rotation around a ~50 µT field.
        let x = (22.0 + 18.0 * sin(t * 0.25)) * 16
        let y = (-8.0 + 18.0 * cos(t * 0.25)) * 16
        let z = 42.0 * 16
        return (Int16(x), Int16(y), Int16(z))
    }

    private func pressureRaw() -> UInt32 {
        UInt32((101_325.0 + 14.0 * sin(elapsed() * 0.3)) * 256)
    }

    // MARK: - Byte helpers

    private nonisolated func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private nonisolated func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private nonisolated func leFloat(_ v: Float) -> [UInt8] { le32(v.bitPattern) }
}
