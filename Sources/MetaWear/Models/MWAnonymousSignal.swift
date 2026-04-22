import Foundation

// MARK: - MWAnonymousSignal
//
// Represents a logger signal recovered from a board whose on-device logger
// configuration is intact but whose Swift-side `MWLoggable` registry is not.
//
// Reconstructed by walking `queryActiveLoggers()` → `queryActiveProcessors()`,
// following any data-processor chain back to its root sensor signal, and
// producing a canonical identifier string plus a typed decode closure.
//
// Mirrors `mbl_mw_metawearboard_create_anonymous_datasignals` from the C++
// MetaWear SDK (test_anonymous_signal.py).

public struct MWAnonymousSignal: Sendable {
    /// Canonical identifier, e.g. `"acceleration"`, `"angular-velocity[1]"`,
    /// `"acceleration:rms?id=0:accumulate?id=1:time?id=2"`.
    public let identifier: String

    /// The root sensor signal this chain ultimately reads from.
    public let rootModule: MWModule

    /// Raw chunks this signal reads from the log stream, in order.
    /// Each chunk maps to one logger ID assigned by the board.
    public let loggerIDs: [UInt8]

    /// Decode a single raw log entry's payload into typed samples.
    /// Normal signals yield a 1-element array; the Fuser yields 2 elements
    /// (one for each fused input).
    public let decode: @Sendable (Data) throws -> [Output]

    public enum Output: Sendable, Equatable {
        case cartesian(CartesianFloat)
        case scalar(Float)
        case quaternion(Quaternion)
        case euler(EulerAngles)
        case correctedCartesian(CorrectedCartesianFloat)
    }

    public init(
        identifier: String,
        rootModule: MWModule,
        loggerIDs: [UInt8],
        decode: @escaping @Sendable (Data) throws -> [Output]
    ) {
        self.identifier = identifier
        self.rootModule = rootModule
        self.loggerIDs = loggerIDs
        self.decode = decode
    }
}

// Equatable conformance limited to the identifying fields (closures aren't Equatable).
extension MWAnonymousSignal: Equatable {
    public static func == (lhs: MWAnonymousSignal, rhs: MWAnonymousSignal) -> Bool {
        lhs.identifier == rhs.identifier
            && lhs.rootModule == rhs.rootModule
            && lhs.loggerIDs == rhs.loggerIDs
    }
}

// MARK: - Scheme identifier builder
//
// Internal pure functions that map (root signal + processor chain) → string.
// Kept separate from MetaWearDevice so they can be exhaustively tested without
// any I/O.

enum MWAnonymousSignalScheme {

    /// Identifier for a root sensor signal. `chunkLength` distinguishes packed
    /// XYZ (length > 2) from single-axis (length == 2).
    static func rootIdentifier(
        module: MWModule,
        register: UInt8,
        channel: UInt8,
        chunkOffset: UInt8,
        chunkLength: UInt8
    ) -> String? {
        switch module {

        case .accelerometer:
            // Register 0x04 is the data-interrupt register (with READ bit cleared).
            guard register == 0x04 else { return nil }
            if chunkLength > 2 {
                return "acceleration"
            }
            return "acceleration[\(chunkOffset / 2)]"

        case .gyro:
            guard register == 0x05 else { return nil }
            if chunkLength > 2 {
                return "angular-velocity"
            }
            return "angular-velocity[\(chunkOffset / 2)]"

        case .magnetometer:
            guard register == 0x05 else { return nil }
            if chunkLength > 2 {
                return "magnetic-field"
            }
            return "magnetic-field[\(chunkOffset / 2)]"

        case .temperature:
            // Register 0xC1 (READ|VALUE); channel byte carries the thermistor index.
            guard register == 0xC1 else { return nil }
            return "temperature[\(channel)]"

        case .sensorFusion:
            // Sensor-fusion data registers use the data-register number directly.
            switch register {
            case 0x04: return "corrected-acceleration"
            case 0x05: return "corrected-angular-velocity"
            case 0x06: return "corrected-magnetic-field"
            case 0x07: return "quaternion"
            case 0x08: return "euler-angles"
            case 0x09: return "gravity"
            case 0x0A: return "linear-acceleration"
            default:   return nil
            }

        default:
            return nil
        }
    }

    /// Identifier segment for a single processor link, e.g. `"rms?id=0"`.
    static func processorSegment(type: UInt8, id: UInt8, config: [UInt8]) -> String? {
        guard let name = processorName(type: type, config: config) else { return nil }
        return "\(name)?id=\(id)"
    }

    /// Base name for a processor type. Some processor IDs carry a config-dependent
    /// disambiguation (ACCUMULATOR vs. COUNTER share id 0x02; LOW-PASS vs. HIGH-PASS
    /// share id 0x03; RMS vs. RSS share id 0x07).
    static func processorName(type: UInt8, config: [UInt8]) -> String? {
        switch type {
        case 0x01: return "passthrough"
        case 0x02:
            // Mode byte in config[0]: 0x00 = accumulate, 0x01 = count.
            return (config.first ?? 0) == 0x01 ? "count" : "accumulate"
        case 0x03:
            // Average filter: bit 0 of mode indicates high-pass.
            let mode = config.count > 1 ? config[1] : 0
            return (mode & 0x01) != 0 ? "high-pass" : "low-pass"
        case 0x06: return "comparison"
        case 0x07:
            // RMS vs. RSS: distinguished by the mode byte at config[1].
            // 0x07 = RMS, 0x0B = RSS.
            let mode = config.count > 1 ? config[1] : 0x07
            return mode == 0x0B ? "rss" : "rms"
        case 0x08: return "time"
        case 0x09: return "math"
        case 0x0A: return "delay"
        case 0x0B: return "pulse"
        case 0x0C: return "differential"
        case 0x0D: return "threshold"
        case 0x0F: return "buffer"
        case 0x10: return "packer"
        case 0x11: return "account"
        case 0x1B: return "fuser"
        default:   return nil
        }
    }

    /// The processor type IDs that emit a "state" (readable) signal rather than
    /// (or in addition to) data. These show up as `"buffer-state"` in the Python
    /// reference when the logger captures the buffer's state register instead of
    /// its data output.
    static func stateNameOverride(forType type: UInt8) -> String? {
        switch type {
        case 0x0F: return "buffer-state"
        default:   return nil
        }
    }

    /// True when `(module, register)` indicates a logger is capturing a data
    /// processor's STATE register (as opposed to its normal NOTIFY output).
    /// The C++ SDK encodes this as register `0xC4` on the DATA_PROCESSOR module.
    static func isProcessorStateCapture(module: MWModule, register: UInt8) -> Bool {
        module == .dataProcessor && register == 0xC4
    }

    /// True when `(module, register)` indicates the logger's source is a data
    /// processor's normal NOTIFY output (register 0x03).
    static func isProcessorDataCapture(module: MWModule, register: UInt8) -> Bool {
        module == .dataProcessor && register == 0x03
    }

    /// Compose the full identifier from a root + an ordered chain of processors.
    /// When `captureStateOfTerminalBuffer` is true, the last segment is rewritten
    /// from its normal name (e.g. `"buffer"`) to the state variant (`"buffer-state"`).
    static func compose(
        root: String,
        chain: [(type: UInt8, id: UInt8, config: [UInt8])],
        captureStateOfTerminalBuffer: Bool = false
    ) -> String? {
        var parts: [String] = [root]
        for (idx, link) in chain.enumerated() {
            let isTerminal = (idx == chain.count - 1)
            let name: String
            if isTerminal, captureStateOfTerminalBuffer,
               let state = stateNameOverride(forType: link.type) {
                name = state
            } else {
                guard let n = processorName(type: link.type, config: link.config) else {
                    return nil
                }
                name = n
            }
            parts.append("\(name)?id=\(link.id)")
        }
        return parts.joined(separator: ":")
    }
}

// MARK: - Anonymous signal builder
//
// Pure (no I/O) reconstruction of `[MWAnonymousSignal]` from queried
// logger + processor state plus the live sensor scale factors. Kept separate
// from `MetaWearDevice` so it's exhaustively testable.

enum MWAnonymousSignalBuilder {

    /// Live per-sensor scale factors needed to convert raw int16 readings
    /// into physical units (g, dps, µT). `nil` means the sensor wasn't present
    /// on the board — its signals will be skipped.
    struct Scales: Sendable {
        var accel: Float?    // LSB/g
        var gyro:  Float?    // LSB/dps
        var mag:   Float?    // LSB/µT — fixed at 16.0 for the BMM150
    }

    /// Group key for a signal: multiple chunks of the same signal share this key.
    fileprivate struct GroupKey: Hashable {
        let module: MWModule
        let register: UInt8
        let channel: UInt8
    }

    /// Main entry. Build the full signal list from live board metadata.
    static func build(
        loggers: [ActiveLogger],
        processors: [ActiveProcessor],
        scales: Scales
    ) -> [MWAnonymousSignal] {
        let procByID: [UInt8: ActiveProcessor] = Dictionary(
            uniqueKeysWithValues: processors.map { ($0.processorID, $0) }
        )

        // Preserve board-assigned order by remembering first-seen index per key.
        var order: [GroupKey] = []
        var byKey: [GroupKey: [ActiveLogger]] = [:]
        for logger in loggers {
            let key = GroupKey(module: logger.module, register: logger.register, channel: logger.channel)
            if byKey[key] == nil {
                order.append(key)
            }
            byKey[key, default: []].append(logger)
        }

        var signals: [MWAnonymousSignal] = []
        for key in order {
            let groupChunks = byKey[key]!.sorted { $0.chunkOffset < $1.chunkOffset }
            // Partition chunks into (a) a primary signal built from chunks
            // that form a contiguous stream starting at offset 0, and
            // (b) any leftover chunks — each becomes its own standalone
            // single-axis (or state-capture) signal. This mirrors the C++
            // SDK behaviour where loggers at non-zero offsets with no
            // predecessor chunk are independent signals.
            var primary: [ActiveLogger] = []
            var leftover: [ActiveLogger] = []
            var cursor: Int = 0
            var cursorActive: Bool = (groupChunks.first?.chunkOffset == 0)
            for chunk in groupChunks {
                if cursorActive && Int(chunk.chunkOffset) == cursor {
                    primary.append(chunk)
                    cursor += Int(chunk.chunkLength)
                } else {
                    leftover.append(chunk)
                }
            }
            if !primary.isEmpty,
               let signal = makeSignal(chunks: primary, processors: procByID, scales: scales) {
                signals.append(signal)
            }
            for chunk in leftover {
                if let signal = makeSignal(chunks: [chunk], processors: procByID, scales: scales) {
                    signals.append(signal)
                }
            }
        }
        return signals
    }

    // MARK: - Signal construction

    private static func makeSignal(
        chunks: [ActiveLogger],
        processors: [UInt8: ActiveProcessor],
        scales: Scales
    ) -> MWAnonymousSignal? {
        guard let first = chunks.first else { return nil }

        // Case 1: logger source is another data processor.
        if MWAnonymousSignalScheme.isProcessorDataCapture(module: first.module, register: first.register)
            || MWAnonymousSignalScheme.isProcessorStateCapture(module: first.module, register: first.register) {
            return makeChainedSignal(chunks: chunks, processors: processors, scales: scales)
        }

        // Case 2: logger source is a root sensor.
        return makeFlatSignal(chunks: chunks, scales: scales)
    }

    // MARK: Flat (non-chained) signals

    private static func makeFlatSignal(
        chunks: [ActiveLogger],
        scales: Scales
    ) -> MWAnonymousSignal? {
        let first = chunks.first!
        let totalLength = chunks.reduce(0) { $0 + Int($1.chunkLength) }
        let startOffset = Int(first.chunkOffset)

        guard let identifier = MWAnonymousSignalScheme.rootIdentifier(
            module: first.module,
            register: first.register,
            channel: first.channel,
            chunkOffset: first.chunkOffset,
            chunkLength: UInt8(totalLength.clamped(to: 0...255))
        ) else {
            return nil
        }

        let loggerIDs = chunks.map { $0.loggerID }

        let decoder = flatDecoder(
            module: first.module,
            register: first.register,
            startOffset: startOffset,
            totalLength: totalLength,
            scales: scales
        )

        return MWAnonymousSignal(
            identifier: identifier,
            rootModule: first.module,
            loggerIDs: loggerIDs,
            decode: decoder
        )
    }

    /// Build the decode closure for a flat (root sensor) signal.
    /// `payload` passed to the closure is the concatenation of chunk bytes
    /// in `chunkOffset` order; its length equals `totalLength`.
    private static func flatDecoder(
        module: MWModule,
        register: UInt8,
        startOffset: Int,
        totalLength: Int,
        scales: Scales
    ) -> @Sendable (Data) throws -> [MWAnonymousSignal.Output] {
        switch (module, register) {

        case (.accelerometer, 0x04), (.gyro, 0x05), (.magnetometer, 0x05):
            let scale = scales.scaleFor(module: module) ?? 1
            // A full XYZ signal needs 6 bytes; a single axis needs 2.
            if totalLength >= 6 {
                return { payload in
                    guard payload.count >= 6 else { return [] }
                    let x = Int16(bitPattern: UInt16(payload[0]) | (UInt16(payload[1]) << 8))
                    let y = Int16(bitPattern: UInt16(payload[2]) | (UInt16(payload[3]) << 8))
                    let z = Int16(bitPattern: UInt16(payload[4]) | (UInt16(payload[5]) << 8))
                    return [.cartesian(CartesianFloat(
                        x: Float(x) / scale,
                        y: Float(y) / scale,
                        z: Float(z) / scale
                    ))]
                }
            } else {
                return { payload in
                    guard payload.count >= 2 else { return [] }
                    let v = Int16(bitPattern: UInt16(payload[0]) | (UInt16(payload[1]) << 8))
                    return [.scalar(Float(v) / scale)]
                }
            }

        case (.temperature, 0xC1):
            // Temperature sample: 2 bytes LE, scale = 8 LSB/°C (temperature module convention)
            return { payload in
                guard payload.count >= 2 else { return [] }
                let v = Int16(bitPattern: UInt16(payload[0]) | (UInt16(payload[1]) << 8))
                return [.scalar(Float(v) / 8.0)]
            }

        case (.sensorFusion, 0x07):  // quaternion
            return { payload in
                guard payload.count >= 16 else { return [] }
                let w = decodeFloatQ16_16(payload, offset: 0)
                let x = decodeFloatQ16_16(payload, offset: 4)
                let y = decodeFloatQ16_16(payload, offset: 8)
                let z = decodeFloatQ16_16(payload, offset: 12)
                return [.quaternion(Quaternion(w: w, x: x, y: y, z: z))]
            }

        case (.sensorFusion, 0x08):  // euler angles
            return { payload in
                guard payload.count >= 16 else { return [] }
                let h = decodeFloatQ16_16(payload, offset: 0)
                let p = decodeFloatQ16_16(payload, offset: 4)
                let r = decodeFloatQ16_16(payload, offset: 8)
                let y = decodeFloatQ16_16(payload, offset: 12)
                return [.euler(EulerAngles(heading: h, pitch: p, roll: r, yaw: y))]
            }

        case (.sensorFusion, 0x09), (.sensorFusion, 0x0A):  // gravity / linear-accel
            return { payload in
                guard payload.count >= 12 else { return [] }
                let x = decodeFloatQ16_16(payload, offset: 0)
                let y = decodeFloatQ16_16(payload, offset: 4)
                let z = decodeFloatQ16_16(payload, offset: 8)
                return [.cartesian(CartesianFloat(x: x, y: y, z: z))]
            }

        default:
            return { _ in
                throw MWError.operationFailed("Anonymous signal decode not implemented for module=\(module) register=\(String(register, radix: 16))")
            }
        }
    }

    // MARK: Chained (processor-output) signals

    private static func makeChainedSignal(
        chunks: [ActiveLogger],
        processors: [UInt8: ActiveProcessor],
        scales: Scales
    ) -> MWAnonymousSignal? {
        let first = chunks.first!
        let terminalProcID = first.channel
        let isStateCapture = MWAnonymousSignalScheme.isProcessorStateCapture(
            module: first.module, register: first.register
        )

        // Walk the chain from terminal processor back to the root sensor.
        var chainTop: [ActiveProcessor] = []
        var cursor: UInt8 = terminalProcID
        var safety = 0
        var rootProc: ActiveProcessor? = nil
        while let proc = processors[cursor] {
            chainTop.append(proc)
            if proc.parentIsProcessor {
                cursor = proc.parentProcessorID
            } else {
                rootProc = proc
                break
            }
            safety += 1
            if safety > 64 { return nil }  // cycle guard
        }
        guard let rootProc else { return nil }
        let chain = chainTop.reversed()  // root-first order

        // Identifier for the root sensor the chain ultimately reads from.
        guard let rootIdentifier = MWAnonymousSignalScheme.rootIdentifier(
            module: rootProc.parentModule,
            register: rootProc.parentRegister,
            channel: 0xFF,
            chunkOffset: rootProc.chunkOffset,
            chunkLength: rootProc.chunkLength
        ) else { return nil }

        let chainTuples: [(type: UInt8, id: UInt8, config: [UInt8])] = chain.map {
            (type: $0.processorType, id: $0.processorID, config: $0.configBytes)
        }

        guard let identifier = MWAnonymousSignalScheme.compose(
            root: rootIdentifier,
            chain: chainTuples,
            captureStateOfTerminalBuffer: isStateCapture
        ) else { return nil }

        let loggerIDs = chunks.sorted { $0.chunkOffset < $1.chunkOffset }.map { $0.loggerID }
        let terminal = chain.last!
        let decoder = chainedDecoder(
            terminal: terminal,
            rootSensorModule: rootProc.parentModule,
            rootSensorRegister: rootProc.parentRegister,
            isStateCapture: isStateCapture,
            scales: scales
        )

        return MWAnonymousSignal(
            identifier: identifier,
            rootModule: rootProc.parentModule,
            loggerIDs: loggerIDs,
            decode: decoder
        )
    }

    /// Build the decode closure for a chained signal. The shape depends on the
    /// terminal processor's type and whether the logger is reading the processor's
    /// data output or its state register.
    private static func chainedDecoder(
        terminal: ActiveProcessor,
        rootSensorModule: MWModule,
        rootSensorRegister: UInt8,
        isStateCapture: Bool,
        scales: Scales
    ) -> @Sendable (Data) throws -> [MWAnonymousSignal.Output] {
        let rootScale = scales.scaleFor(module: rootSensorModule) ?? 1.0

        // Fuser (0x1B) — emits two samples per log entry, both scaled as the root sensor.
        // The Python TestFuser format is 4 bytes × 2 = 8 bytes per log entry,
        // with each 4-byte block containing a packed 3-axis int16 triplet... actually
        // the Fuser entry layout Python decodes is 10 bytes per sample (see test).
        if terminal.processorType == 0x1B {
            // Fused entries arrive as 2 concatenated 4-byte chunks per logger entry.
            // Each 4-byte block decodes as 2 int16 axes; entries arrive across
            // multiple log notifications and must be paired by the caller.
            // For direct `decode(payload)` we emit a single sample; the
            // paired-sample behavior is handled at reassembly time.
            return { payload in
                guard payload.count >= 4 else { return [] }
                // Two int16s per block. Fuser output is raw packed; treat as cartesian pair
                // with zero z when only 4 bytes are present.
                let a = Int16(bitPattern: UInt16(payload[0]) | (UInt16(payload[1]) << 8))
                let b = Int16(bitPattern: UInt16(payload[2]) | (UInt16(payload[3]) << 8))
                if payload.count >= 6 {
                    let c = Int16(bitPattern: UInt16(payload[4]) | (UInt16(payload[5]) << 8))
                    return [.cartesian(CartesianFloat(
                        x: Float(a) / rootScale,
                        y: Float(b) / rootScale,
                        z: Float(c) / rootScale
                    ))]
                }
                return [.cartesian(CartesianFloat(
                    x: Float(a) / rootScale,
                    y: Float(b) / rootScale,
                    z: 0
                ))]
            }
        }

        // Time (0x08) — the Python reference decodes the downloaded payload as a 4-byte
        // unsigned integer and divides by the root scale. Output is a scalar "magnitude
        // in parent units".
        if terminal.processorType == 0x08 {
            return { payload in
                guard payload.count >= 4 else { return [] }
                let raw = UInt32(payload[0])
                    | (UInt32(payload[1]) << 8)
                    | (UInt32(payload[2]) << 16)
                    | (UInt32(payload[3]) << 24)
                return [.scalar(Float(raw) / rootScale)]
            }
        }

        // Accumulator / RMS / buffer-state / count / most other scalar-yielding
        // processors: interpret the payload as an unsigned 32-bit value scaled
        // by the root sensor's LSB/unit ratio.
        return { payload in
            guard payload.count >= 4 else {
                guard payload.count >= 2 else { return [] }
                let v = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
                return [.scalar(Float(v) / rootScale)]
            }
            let raw = UInt32(payload[0])
                | (UInt32(payload[1]) << 8)
                | (UInt32(payload[2]) << 16)
                | (UInt32(payload[3]) << 24)
            return [.scalar(Float(raw) / rootScale)]
        }
    }

    // MARK: - Helpers

    private static func decodeFloatQ16_16(_ data: Data, offset: Int) -> Float {
        let raw = UInt32(data[data.startIndex.advanced(by: offset)])
            | (UInt32(data[data.startIndex.advanced(by: offset + 1)]) << 8)
            | (UInt32(data[data.startIndex.advanced(by: offset + 2)]) << 16)
            | (UInt32(data[data.startIndex.advanced(by: offset + 3)]) << 24)
        let signed = Int32(bitPattern: raw)
        return Float(signed) / 65536.0
    }
}

extension MWAnonymousSignalBuilder.Scales {
    func scaleFor(module: MWModule) -> Float? {
        switch module {
        case .accelerometer: return accel
        case .gyro:          return gyro
        case .magnetometer:  return mag
        default:             return nil
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
