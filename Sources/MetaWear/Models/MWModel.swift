import Foundation

// MARK: - MWModel

/// The MetaWear board model in use.
///
/// Only MMS and MMRL are supported. Derived from the Model Number String
/// BLE characteristic (0x2A24), which the firmware encodes as the integer
/// `MblMwModel` value (10 = MMRL, 12 = MMS).
///
/// ```swift
/// let model = device.deviceInfo?.model   // .motionS or .motionRL
/// print(model.name)                      // "MetaMotion S"
/// ```
public enum MWModel: Sendable, Equatable {
    /// MetaMotion RL — BMI160 accelerometer/gyroscope.
    case motionRL
    /// MetaMotion S — BMI270 accelerometer/gyroscope, extra flash.
    case motionS
    /// Any board whose model number is not 10 or 12.
    case unknown(modelNumber: String)

    // MARK: Init

    /// Initialise from the Model Number String BLE characteristic value.
    public init(modelNumber: String) {
        switch modelNumber.trimmingCharacters(in: .whitespaces) {
        case "10": self = .motionRL
        case "12": self = .motionS
        default:   self = .unknown(modelNumber: modelNumber)
        }
    }

    // MARK: Display

    public var name: String {
        switch self {
        case .motionRL:               return "MetaMotion RL"
        case .motionS:                return "MetaMotion S"
        case .unknown(let n):         return "Unknown (\(n))"
        }
    }

    // MARK: Capability

    /// MMS has larger on-board flash and requires `flush_page` before log download.
    public var hasMMS: Bool { self == .motionS }
}

// MARK: - MWDeviceInformation convenience

public extension MWDeviceInformation {
    /// The board model derived from `modelNumber`.
    var model: MWModel { MWModel(modelNumber: modelNumber) }
}
