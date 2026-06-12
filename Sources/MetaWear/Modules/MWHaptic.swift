import Foundation

// MARK: - Haptic pulse command

/// Triggers a single haptic (vibration motor) or buzzer pulse.
///
/// Usage:
/// ```swift
/// try await device.send(MWHaptic.motor(dutyCycle: 80, pulseWidth: 500))
/// try await device.send(MWHaptic.buzzer(pulseWidth: 200))
/// ```
public enum MWHaptic {

    /// Actuator type: ERM haptic motor or piezo buzzer.
    public enum Mode: UInt8, Sendable {
        case motor  = 0x00
        case buzzer = 0x01
    }

    /// Command: fire one pulse on the haptic motor.
    ///
    /// - Parameters:
    ///   - dutyCycle: Vibration strength, 0–100 (%).
    ///   - pulseWidth: Duration in milliseconds (max 65535).
    public static func motor(dutyCycle: UInt8 = 100, pulseWidth: UInt16 = 500) -> Pulse {
        Pulse(mode: .motor, dutyCycle: dutyCycle, pulseWidth: pulseWidth)
    }

    /// Command: fire one pulse on the buzzer.
    ///
    /// - Parameter pulseWidth: Duration in milliseconds.
    public static func buzzer(pulseWidth: UInt16 = 200) -> Pulse {
        Pulse(mode: .buzzer, dutyCycle: 100, pulseWidth: pulseWidth)
    }

    // MARK: - Pulse command

    /// One-shot pulse command for the haptic motor or buzzer. Prefer the
    /// `MWHaptic.motor(...)` / `MWHaptic.buzzer(...)` factories over building
    /// this directly.
    public struct Pulse: MWCommand, Sendable {
        public let mode: Mode
        /// Strength of the pulse (0–100 %).
        public let dutyCycle: UInt8
        /// Duration of the pulse in milliseconds.
        public let pulseWidth: UInt16

        public init(mode: Mode, dutyCycle: UInt8, pulseWidth: UInt16) {
            self.mode       = mode
            self.dutyCycle  = min(dutyCycle, 100)
            self.pulseWidth = pulseWidth
        }

        /// Command bytes: [0x08, 0x01, dutyCycle_scaled, pulseWidth_lo, pulseWidth_hi, mode]
        /// Motor duty cycle: 0–100% → 0–248 (hardware range).
        /// Buzzer always uses 0x7F regardless of dutyCycle.
        public var commandData: Data {
            let dcByte: UInt8 = mode == .buzzer
                ? 0x7F
                : UInt8(min(248, UInt16(dutyCycle) * 248 / 100))
            return MWPacket.command(.haptic, 0x01, [
                dcByte,
                UInt8(pulseWidth & 0xFF),
                UInt8(pulseWidth >> 8),
                mode.rawValue
            ])
        }
    }
}
