import Foundation

// MARK: - MWBoschIMUSensor
//
// The four Bosch IMU sensors on MetaMotion boards — BMI160 accelerometer,
// BMI270 accelerometer, BMI160 gyroscope, BMI270 gyroscope — share an
// identical MetaWear-protocol pattern at the command level:
//
//   register 0x01  POWER                  →  [0x01] start sampling, [0x00] stop
//   register 0x02  DATA_INTERRUPT_ENABLE  →  [0x01, 0x00] enable, [0x00, 0x01] disable
//   register 0x03  DATA_INTERRUPT_CONFIG  →  [conf_byte, range_byte]
//
// Only the per-chip config-byte encoding and the data-register opcode differ.
// This protocol captures the shared portion: each chip variant declares only
// its module, data registers, `configPayload`, and `Sample = CartesianFloat`
// scale factor — `enableCommand`, `startCommand`, `stopCommand`,
// `disableCommand`, and `configureCommands` are synthesized below.
//
// Internal — the concrete public types (`MWAccelerometerBMI160`, etc.) remain
// the supported API surface. This protocol exists only to dedupe boilerplate.

/// Internal abstraction shared by the four Bosch IMU sensors (BMI160 / BMI270
/// accelerometer and gyroscope). Synthesises the common `power` / `interrupt
/// enable` / `interrupt config` register writes so each concrete struct only
/// declares its `configPayload` and scale factor. See the file header for the
/// full register layout.
protocol MWBoschIMUSensor: MWLoggable where Sample == CartesianFloat {
    /// The 2-byte chip-specific config payload written to register 0x03
    /// (`DATA_INTERRUPT_CONFIG`).
    ///
    /// - Accelerometer: `[acc_conf, range_byte]`. `acc_conf` packs ODR, BWP,
    ///   and the chip-specific under-sampling / filter-performance bit.
    /// - Gyroscope: `[gyro_conf, range_byte]`. Same encoding on BMI160 and BMI270.
    var configPayload: [UInt8] { get }
}

extension MWBoschIMUSensor {
    // The opcodes below (0x01 / 0x02 / 0x03) are the standard sensor-module
    // register layout shared by every Bosch IMU. Named equivalents per module
    // live in `MWAccelerometerRegister` and `MWGyroscopeRegister`; reaching
    // into one of them from this shared extension would force the protocol
    // to know which module it belongs to. The wire bytes are identical, so
    // the bare hex with this comment is the least-coupled option.

    public var enableCommand: Data {
        MWPacket.command(module, 0x02, [0x01, 0x00])
    }

    public var startCommand: Data {
        MWPacket.command(module, 0x01, [0x01])
    }

    public var stopCommand: Data {
        MWPacket.command(module, 0x01, [0x00])
    }

    public var disableCommand: Data {
        MWPacket.command(module, 0x02, [0x00, 0x01])
    }

    public var configureCommands: [Data] {
        [MWPacket.command(module, 0x03, configPayload)]
    }
}
