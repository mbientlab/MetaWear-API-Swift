import Foundation

// MARK: - LED pattern

/// The timing and intensity parameters for one color channel's LED pattern.
public struct MWLEDPattern: Sendable, Equatable {
    /// LED brightness during the high phase (0–31).
    public var highIntensity: UInt8
    /// LED brightness during the low phase (0–31). Usually 0.
    public var lowIntensity: UInt8
    /// Time (ms) to ramp from lowIntensity to highIntensity.
    public var riseTime: UInt16
    /// Time (ms) to hold at highIntensity.
    public var highTime: UInt16
    /// Time (ms) to ramp from highIntensity back to lowIntensity.
    public var fallTime: UInt16
    /// Time (ms) to hold at lowIntensity before the next pulse.
    public var pulseDuration: UInt16
    /// Time (ms) before the pattern starts. Useful to phase-offset multiple channels.
    public var delay: UInt16
    /// Number of pulses to play. 0 = repeat indefinitely.
    public var repeatCount: UInt8

    public init(
        highIntensity: UInt8  = 31,
        lowIntensity: UInt8   = 0,
        riseTime: UInt16      = 0,
        highTime: UInt16      = 500,
        fallTime: UInt16      = 0,
        pulseDuration: UInt16 = 1000,
        delay: UInt16         = 0,
        repeatCount: UInt8    = 0
    ) {
        self.highIntensity = highIntensity
        self.lowIntensity  = lowIntensity
        self.riseTime      = riseTime
        self.highTime      = highTime
        self.fallTime      = fallTime
        self.pulseDuration = pulseDuration
        self.delay         = delay
        self.repeatCount   = repeatCount
    }
}

// MARK: - Preset patterns

public extension MWLEDPattern {
    /// Solid on (no blinking). lowIntensity == highIntensity keeps the LED lit during the low phase.
    static var solid: MWLEDPattern {
        MWLEDPattern(highIntensity: 31, lowIntensity: 31, riseTime: 0, highTime: 500,
                     fallTime: 0, pulseDuration: 1000, repeatCount: .max)
    }

    /// Simple blink: 50 ms on, 450 ms off.
    static var blink: MWLEDPattern {
        MWLEDPattern(highIntensity: 31, riseTime: 0, highTime: 50,
                     fallTime: 0, pulseDuration: 500, repeatCount: .max)
    }

    /// Soft breathe: ramp up and down over 2 seconds.
    static var breathe: MWLEDPattern {
        MWLEDPattern(highIntensity: 31, riseTime: 725, highTime: 500,
                     fallTime: 725, pulseDuration: 2000, repeatCount: .max)
    }

    /// Single short flash (3 pulses of 100 ms).
    static var flash: MWLEDPattern {
        MWLEDPattern(highIntensity: 31, riseTime: 0, highTime: 100,
                     fallTime: 0, pulseDuration: 500, repeatCount: 3)
    }
}

// MARK: - LED commands

/// Namespace for MetaWear LED (module 0x02) commands.
public enum MWLED {

    /// Color channels available on all MetaWear boards.
    public enum Color: UInt8, Sendable, CaseIterable {
        case green = 0, red = 1, blue = 2
    }

    // MARK: - Command types

    /// Write a pattern to one color channel.
    /// Must be followed by `Play` to start the animation.
    public struct SetPattern: MWCommand, Sendable {
        public let color: Color
        public let pattern: MWLEDPattern

        public init(color: Color, pattern: MWLEDPattern) {
            self.color   = color
            self.pattern = pattern
        }

        /// Convenience: one-liner to build a command from a preset.
        public init(color: Color, _ preset: MWLEDPattern) {
            self.init(color: color, pattern: preset)
        }

        public var commandData: Data {
            var bytes: [UInt8] = [color.rawValue, 0x02,
                                  pattern.highIntensity, pattern.lowIntensity]
            func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
            bytes += le16(pattern.riseTime)
            bytes += le16(pattern.highTime)
            bytes += le16(pattern.fallTime)
            bytes += le16(pattern.pulseDuration)
            bytes += le16(pattern.delay)
            bytes.append(pattern.repeatCount)
            return MWPacket.command(.led, 0x03, bytes)
        }
    }

    /// Start LED playback (plays all configured channels).
    public struct Play: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.led, 0x01, [0x01]) }
    }

    /// Start LED playback and immediately play any patterns programmed in the future.
    /// Use this instead of `Play` when you want subsequent `SetPattern` commands to start automatically.
    public struct Autoplay: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.led, 0x01, [0x02]) }
    }

    /// Pause playback without clearing patterns.
    public struct Pause: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.led, 0x01, [0x00]) }
    }

    /// Stop playback.
    public struct Stop: MWCommand, Sendable {
        /// When `true`, also erases all configured patterns from the board.
        public let clearPattern: Bool

        public init(clearPattern: Bool = true) {
            self.clearPattern = clearPattern
        }

        public var commandData: Data {
            MWPacket.command(.led, 0x02, [clearPattern ? 0x01 : 0x00])
        }
    }

    // MARK: - Multi-channel convenience

    /// Configure multiple color channels at once and optionally start playback immediately.
    ///
    /// Usage — solid white:
    /// ```swift
    /// try await device.send(MWLED.SetAllChannels(
    ///     red: .solid, green: .solid, blue: .solid, autoPlay: true
    /// ))
    /// ```
    public struct SetAllChannels: MWCommand, Sendable {
        public let red:    MWLEDPattern?
        public let green:  MWLEDPattern?
        public let blue:   MWLEDPattern?
        /// When `true`, a `Play` command is appended after the pattern bytes.
        public let autoPlay: Bool

        public init(
            red:      MWLEDPattern? = nil,
            green:    MWLEDPattern? = nil,
            blue:     MWLEDPattern? = nil,
            autoPlay: Bool = true
        ) {
            self.red      = red
            self.green    = green
            self.blue     = blue
            self.autoPlay = autoPlay
        }

        public var commandData: Data {
            // SetAllChannels cannot be encoded as a single BLE packet;
            // callers should use `MetaWearDevice.setLED(_:autoPlay:)` instead,
            // which sends one command per channel. This property is provided
            // for conformance only and encodes the first non-nil channel.
            if let g = green { return SetPattern(color: .green, pattern: g).commandData }
            if let r = red   { return SetPattern(color: .red,   pattern: r).commandData }
            if let b = blue  { return SetPattern(color: .blue,  pattern: b).commandData }
            return Data()
        }
    }
}

// MARK: - MetaWearDevice LED convenience

public extension MetaWearDevice {

    /// Set one or more LED color channels and optionally start playback.
    ///
    /// ```swift
    /// try await device.setLED(red: .blink, green: nil, blue: .solid, autoPlay: true)
    /// ```
    func setLED(
        red:      MWLEDPattern? = nil,
        green:    MWLEDPattern? = nil,
        blue:     MWLEDPattern? = nil,
        autoPlay: Bool = true
    ) async throws {
        // Always reset first — required by firmware before writing new patterns.
        try await send(MWLED.Stop(clearPattern: true))
        if let g = green { try await send(MWLED.SetPattern(color: .green, pattern: g)) }
        if let r = red   { try await send(MWLED.SetPattern(color: .red,   pattern: r)) }
        if let b = blue  { try await send(MWLED.SetPattern(color: .blue,  pattern: b)) }
        if autoPlay      { try await send(MWLED.Play()) }
    }

    /// Stop all LED channels and optionally clear patterns.
    func stopLED(clearPattern: Bool = true) async throws {
        try await send(MWLED.Stop(clearPattern: clearPattern))
    }
}
