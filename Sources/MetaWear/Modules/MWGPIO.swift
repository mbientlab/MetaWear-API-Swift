import Foundation

// MARK: - GPIO (module 0x05)

/// Commands and streaming types for the MetaWear GPIO module.
///
/// Pins are referenced by their 0-based index on the board connector.
/// Typical MetaWear boards expose pins 0–3; check the board's hardware guide
/// for the exact count and capabilities.
///
/// Usage — read a digital input:
/// ```swift
/// let high = try await device.readDigital(pin: 0)
/// ```
///
/// Usage — stream pin-change notifications:
/// ```swift
/// let changes = try await device.stream(MWGPIOPinChange(pin: 0, type: .any))
/// for try await change in changes {
///     print("Pin 0 is now", change.value ? "HIGH" : "LOW")
/// }
/// ```
public enum MWGPIO {

    // MARK: - Pull configuration

    /// Configures the internal pull resistor on a digital input pin.
    public enum Pull: Sendable {
        /// Internal pull-up resistor active (~50 kΩ to VDD).
        case up
        /// Internal pull-down resistor active (~50 kΩ to GND).
        case down
        /// No pull — the pin floats if undriven.
        case none

        var register: UInt8 {
            switch self {
            case .up:   return 0x03
            case .down: return 0x04
            case .none: return 0x05
            }
        }
    }

    // MARK: - Pin-change type

    /// Which edge(s) on the pin trigger a notification.
    public enum ChangeType: UInt8, Sendable {
        /// Notify on rising edge (LOW → HIGH).
        case rising  = 1
        /// Notify on falling edge (HIGH → LOW).
        case falling = 2
        /// Notify on any edge.
        case any     = 3
    }

    // MARK: - Analog read mode

    /// Selects how an analog input pin is sampled.
    public enum AnalogReadMode: Sendable {
        /// Read the pin's voltage against the absolute reference (register 0x06).
        /// Useful for an absolute millivolt reading.
        case absoluteReference
        /// Read the pin's voltage as a ratio of the supply (register 0x07).
        /// Raw ADC count, 0–1023.
        case adc

        /// Raw register byte (no read bit).
        public var register: UInt8 {
            switch self {
            case .absoluteReference: return 0x06
            case .adc:               return 0x07
            }
        }

        /// Register byte with the read bit set (0x80).
        public var readRegister: UInt8 { register | 0x80 }

        /// Register byte with read (0x80) and silent (0x40) bits set.
        /// Silent reads emit a response once and do not feed the notification dispatcher.
        public var silentReadRegister: UInt8 { register | 0xC0 }
    }

    // MARK: - Enhanced analog read parameters

    /// Optional pullup/pulldown/virtual-pin/delay parameters for an enhanced analog read.
    /// Only honoured by GPIO module revision ≥ 2.
    ///
    /// Mirrors C++ `MblMwGpioAnalogReadParameters`. `delay_us` is packed into one byte
    /// by shifting right by 2 (the firmware divides by 4 internally), so the payload
    /// accepts values in the range [0, 1020] µs.
    public struct AnalogReadParameters: Sendable {
        /// Sentinel matching C++ `MBL_MW_GPIO_UNUSED_PIN`.
        public static let unusedPin: UInt8 = 0xFF

        /// Pin to drive high before sampling, or `unusedPin`.
        public let pullupPin: UInt8
        /// Pin to drive low before sampling, or `unusedPin`.
        public let pulldownPin: UInt8
        /// Pin ID the response is tagged with, or `unusedPin` to use the physical pin.
        public let virtualPin: UInt8
        /// How long to wait between pull-setup and sampling, in microseconds (0–1020).
        public let delayMicroseconds: UInt16

        /// Default parameter set: all pins unused, zero delay.
        /// Byte layout emitted: `[0xFF, 0xFF, 0x00, 0xFF]`.
        public static let defaults = AnalogReadParameters()

        public init(pullupPin: UInt8 = unusedPin,
                    pulldownPin: UInt8 = unusedPin,
                    virtualPin: UInt8 = unusedPin,
                    delayMicroseconds: UInt16 = 0) {
            self.pullupPin         = pullupPin
            self.pulldownPin       = pulldownPin
            self.virtualPin        = virtualPin
            self.delayMicroseconds = min(delayMicroseconds, 1020)
        }

        /// Delay byte — firmware divides by 4, so we pre-shift.
        public var encodedDelay: UInt8 { UInt8(delayMicroseconds >> 2) }
    }

    // MARK: - Commands

    /// Drive a digital output pin HIGH.
    public struct SetHigh: MWCommand, Sendable {
        public let pin: UInt8
        public init(pin: UInt8) { self.pin = pin }
        public var commandData: Data { MWPacket.command(.gpio, 0x01, [pin]) }
    }

    /// Drive a digital output pin LOW.
    public struct SetLow: MWCommand, Sendable {
        public let pin: UInt8
        public init(pin: UInt8) { self.pin = pin }
        public var commandData: Data { MWPacket.command(.gpio, 0x02, [pin]) }
    }

    /// Set the pull configuration on a digital input pin.
    public struct SetPull: MWCommand, Sendable {
        public let pin: UInt8
        public let pull: Pull
        public init(pin: UInt8, pull: Pull) { self.pin = pin; self.pull = pull }
        public var commandData: Data { MWPacket.command(.gpio, pull.register, [pin]) }
    }

    /// Configure which edge(s) on a pin trigger a change notification.
    public struct ConfigurePinChange: MWCommand, Sendable {
        public let pin: UInt8
        public let type: ChangeType
        public init(pin: UInt8, type: ChangeType) { self.pin = pin; self.type = type }
        public var commandData: Data { MWPacket.command(.gpio, 0x09, [pin, type.rawValue]) }
    }

    /// Begin pin-change monitoring on a pin. Mirrors `mbl_mw_gpio_start_pin_monitoring`.
    public struct StartPinMonitor: MWCommand, Sendable {
        public let pin: UInt8
        public init(pin: UInt8) { self.pin = pin }
        public var commandData: Data { MWPacket.command(.gpio, 0x0B, [pin, 0x01]) }
    }

    /// Stop pin-change monitoring on a pin. Mirrors `mbl_mw_gpio_stop_pin_monitoring`.
    public struct StopPinMonitor: MWCommand, Sendable {
        public let pin: UInt8
        public init(pin: UInt8) { self.pin = pin }
        public var commandData: Data { MWPacket.command(.gpio, 0x0B, [pin, 0x00]) }
    }

    // MARK: - Read command builders

    /// Build a digital-input one-shot read command.
    ///
    /// - Parameters:
    ///   - pin: GPIO pin index.
    ///   - silent: When `true`, emits `0xC8` (read + silent bit). The firmware responds once
    ///     but does not push the sample through the notification dispatcher.
    public struct DigitalRead: MWCommand, Sendable {
        public let pin: UInt8
        public let silent: Bool
        public init(pin: UInt8, silent: Bool = false) {
            self.pin = pin
            self.silent = silent
        }
        public var commandData: Data {
            let register: UInt8 = silent ? 0xC8 : 0x88
            return Data([MWModule.gpio.rawValue, register, pin])
        }
    }

    /// Build an analog-input one-shot read command — basic or enhanced form.
    ///
    /// - When `parameters` is `nil`, a 3-byte command is produced (pre-revision-2 boards).
    /// - When `parameters` is non-`nil`, a 7-byte command is produced with the pullup/
    ///   pulldown/delay/virtual-pin fields (revision ≥ 2 boards).
    public struct AnalogRead: MWCommand, Sendable {
        public let mode: AnalogReadMode
        public let pin: UInt8
        public let silent: Bool
        public let parameters: AnalogReadParameters?

        public init(mode: AnalogReadMode,
                    pin: UInt8,
                    silent: Bool = false,
                    parameters: AnalogReadParameters? = nil) {
            self.mode = mode
            self.pin = pin
            self.silent = silent
            self.parameters = parameters
        }

        public var commandData: Data {
            let register: UInt8 = silent ? mode.silentReadRegister : mode.readRegister
            if let p = parameters {
                return Data([MWModule.gpio.rawValue, register, pin,
                             p.pullupPin, p.pulldownPin, p.encodedDelay, p.virtualPin])
            } else {
                return Data([MWModule.gpio.rawValue, register, pin])
            }
        }
    }
}

// MARK: - GPIO pin-change stream

/// A streamable signal that fires on every configured edge of a GPIO pin.
public struct MWGPIOPinChange: MWStreamable {
    public typealias Sample = MWGPIOSample

    public let pin: UInt8
    public let changeType: MWGPIO.ChangeType

    public init(pin: UInt8, type: MWGPIO.ChangeType = .any) {
        self.pin = pin
        self.changeType = type
    }

    // MARK: MWSensor

    public var module: MWModule { .gpio }
    public var dataRegister: UInt8 { 0x0A }       // PIN_CHANGE_NOTIFY

    // MARK: MWStreamable

    public var configureCommands: [Data] {[
        MWPacket.command(.gpio, 0x09, [pin, changeType.rawValue])  // ConfigurePinChange
    ]}
    public var enableCommand:  Data { MWPacket.command(.gpio, 0x0B, [pin, 0x01]) }
    public var startCommand:   Data { Data() }   // no global start needed
    public var stopCommand:    Data { Data() }
    public var disableCommand: Data { MWPacket.command(.gpio, 0x0B, [pin, 0x00]) }

    public func parseSample(from packet: Data) throws -> MWGPIOSample {
        guard packet.count >= 4 else {
            throw MWError.operationFailed("GPIO pin-change packet too short: \(packet.count)")
        }
        // Packet: [0x05, 0x0A, pin, state]
        return MWGPIOSample(pin: packet[2], isHigh: packet[3] != 0)
    }
}

// MARK: - GPIO sample

/// The state of a GPIO pin at the moment of a change notification.
public struct MWGPIOSample: Sendable {
    public let pin: UInt8
    public let isHigh: Bool
}

// MARK: - MetaWearDevice GPIO convenience

public extension MetaWearDevice {

    /// Read the current state of a digital input pin.
    /// - Returns: `true` if the pin is HIGH.
    func readDigital(pin: UInt8) async throws -> Bool {
        let packet = try await sendRead(
            command: Data([MWModule.gpio.rawValue, 0x88, pin]),
            awaitModule: .gpio, awaitRegister: 0x08
        )
        guard packet.count >= 4 else {
            throw MWError.operationFailed("GPIO digital read response too short")
        }
        return packet[3] != 0
    }

    /// Read the analog value from a pin using the absolute voltage reference.
    /// - Returns: Voltage in millivolts (raw ADC value, 0–65535).
    func readAnalogAbsolute(pin: UInt8) async throws -> UInt16 {
        let packet = try await sendRead(
            command: Data([MWModule.gpio.rawValue, 0x86, pin]),
            awaitModule: .gpio, awaitRegister: 0x06
        )
        guard packet.count >= 5 else {
            throw MWError.operationFailed("GPIO analog (abs) read response too short")
        }
        return MWPacketParser.parseUInt16LE(packet, offset: 3)
    }

    /// Read the raw ADC value from an analog input pin.
    /// - Returns: Raw 10-bit ADC count (0–1023).
    func readAnalogADC(pin: UInt8) async throws -> UInt16 {
        let packet = try await sendRead(
            command: Data([MWModule.gpio.rawValue, 0x87, pin]),
            awaitModule: .gpio, awaitRegister: 0x07
        )
        guard packet.count >= 5 else {
            throw MWError.operationFailed("GPIO analog (ADC) read response too short")
        }
        return MWPacketParser.parseUInt16LE(packet, offset: 3)
    }

    /// Enhanced analog read (absolute reference) with optional pullup/pulldown/delay/virtual pin.
    /// Board GPIO module revision must be ≥ 2 for these parameters to be honoured.
    /// - Returns: Voltage in millivolts (raw ADC value, 0–65535).
    func readAnalogAbsolute(pin: UInt8,
                            parameters: MWGPIO.AnalogReadParameters) async throws -> UInt16 {
        let cmd = MWGPIO.AnalogRead(mode: .absoluteReference, pin: pin, parameters: parameters).commandData
        let packet = try await sendRead(command: cmd, awaitModule: .gpio, awaitRegister: 0x06)
        guard packet.count >= 5 else {
            throw MWError.operationFailed("GPIO analog (abs) read response too short")
        }
        return MWPacketParser.parseUInt16LE(packet, offset: 3)
    }

    /// Enhanced analog ADC read with optional pullup/pulldown/delay/virtual pin.
    /// Board GPIO module revision must be ≥ 2 for these parameters to be honoured.
    /// - Returns: Raw 10-bit ADC count (0–1023).
    func readAnalogADC(pin: UInt8,
                       parameters: MWGPIO.AnalogReadParameters) async throws -> UInt16 {
        let cmd = MWGPIO.AnalogRead(mode: .adc, pin: pin, parameters: parameters).commandData
        let packet = try await sendRead(command: cmd, awaitModule: .gpio, awaitRegister: 0x07)
        guard packet.count >= 5 else {
            throw MWError.operationFailed("GPIO analog (ADC) read response too short")
        }
        return MWPacketParser.parseUInt16LE(packet, offset: 3)
    }
}
