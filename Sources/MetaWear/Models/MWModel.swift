import Foundation

// MARK: - MWModel

/// The MetaWear board model in use.
///
/// Only MetaMotion R / RL and MetaMotion S are supported by this SDK. The model
/// is derived from the Model Number BLE characteristic (`0x2A24`), which the
/// firmware encodes as a small integer string per `MblMwModel`:
///
/// | Model number | Board                              | Hardware revisions               |
/// |:------------:|:-----------------------------------|:---------------------------------|
/// | `"5"`        | MetaMotion R / RL (BMI160)         | `r0.1`, `r0.2`, `r0.3`, `r0.4`, `r0.5` |
/// | `"8"`        | MetaMotion S (BMI270)              | `r0.1`                           |
///
/// Anything else maps to `.unknown(modelNumber:)`. Mirrors
/// `MetaWear-SDK-Cpp/src/metawear/impl/cpp/metawearboard.cpp::mbl_mw_metawearboard_get_model`.
///
/// ```swift
/// let model = device.deviceInfo?.model       // .motionRL or .motionS
/// print(model?.name)                          // "MetaMotion R / RL"
/// print(model?.supportedHardwareRevisions)    // ["r0.1", ..., "r0.5"]
/// ```
public enum MWModel: Sendable, Equatable {
    /// MetaMotion R / RL — BMI160 accelerometer + gyroscope. Both R and RL
    /// share model number `"5"`; the C++ SDK distinguishes them by the
    /// presence of an ambient-light sensor, but for this SDK the protocol
    /// surface is identical so we treat them as a single case.
    case motionRL
    /// MetaMotion S — BMI270 accelerometer + gyroscope, extra flash.
    case motionS
    /// Any board whose model number is not `"5"` or `"8"`.
    case unknown(modelNumber: String)

    // MARK: Init

    /// Initialise from the Model Number BLE characteristic value.
    public init(modelNumber: String) {
        switch modelNumber.trimmingCharacters(in: .whitespaces) {
        case "5":  self = .motionRL
        case "8":  self = .motionS
        default:   self = .unknown(modelNumber: modelNumber)
        }
    }

    // MARK: Display

    public var name: String {
        switch self {
        case .motionRL:               return "MetaMotion R / RL"
        case .motionS:                return "MetaMotion S"
        case .unknown(let n):         return "Unknown (\(n))"
        }
    }

    // MARK: Capability

    /// MMS has larger on-board flash and requires `flush_page` before log download.
    public var hasMMS: Bool { self == .motionS }

    // MARK: Hardware revision validation

    /// Hardware revisions known to ship for this model, in shipping order.
    /// Each entry is the canonical `r0.X` form. Empty for `.unknown`.
    public var supportedHardwareRevisions: [String] {
        switch self {
        case .motionRL: return ["r0.1", "r0.2", "r0.3", "r0.4", "r0.5"]
        case .motionS:  return ["r0.1"]
        case .unknown:  return []
        }
    }

    /// Whether the given hardware revision string ships for this model.
    /// Accepts both the canonical `r0.X` form and the bare `0.X` form that
    /// some firmware revisions report in the BLE Hardware Revision String
    /// characteristic — the comparison is case-insensitive and tolerates a
    /// missing leading `r`.
    public func isHardwareRevisionSupported(_ revision: String) -> Bool {
        let normalized = MWModel.normalize(revision)
        return supportedHardwareRevisions
            .map(MWModel.normalize)
            .contains(normalized)
    }

    /// Strip surrounding whitespace, lowercase, drop a leading `r` so `"R0.4"`,
    /// `"r0.4"`, and `"0.4"` all collapse to `"0.4"`.
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("r") { t.removeFirst() }
        return t
    }
}

// MARK: - MWDeviceInformation convenience

public extension MWDeviceInformation {
    /// The board model derived from `modelNumber`.
    var model: MWModel { MWModel(modelNumber: modelNumber) }

    /// `true` when `hardwareRevision` is one of the documented revisions for
    /// the detected `model`. Returns `false` for unknown models or revisions
    /// that haven't been validated against this SDK.
    var isHardwareRevisionSupported: Bool {
        model.isHardwareRevisionSupported(hardwareRevision)
    }
}
