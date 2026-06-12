import Foundation

/// Errors raised by the MetaWear SDK.
///
/// All throwing entry points (`MetaWearDevice`, `MetaWearScanner`, command builders)
/// propagate this single error type rather than mixing Foundation / CoreBluetooth /
/// custom errors. Catch by case, not by string-matching `localizedDescription`.
public enum MWError: Error, Sendable {
    /// The host platform reports Bluetooth as unsupported (simulator, Mac without BLE radio).
    case bluetoothUnsupported
    /// The user has not granted (or has revoked) Bluetooth permission for this app.
    /// Surface this to your UI — programmatic recovery is not possible.
    case bluetoothUnauthorized
    /// Bluetooth is supported and authorized but the radio is currently off.
    /// Retry once `CBCentralManager` reports `.poweredOn`.
    case bluetoothPoweredOff
    /// The operation reached the SDK / firmware but did not succeed.
    /// The associated string is a human-readable diagnostic (not stable for parsing).
    /// Examples: a sensor responded with malformed bytes; a macro slot is exhausted;
    /// a feature is unsupported on this firmware revision.
    case operationFailed(String)
    /// The operation is not legal in the device's current state machine position
    /// (e.g. `startStream` while already streaming, `downloadLogs` while logging).
    /// The associated string names the offending state.
    case invalidState(String)
    /// The operation didn't receive a response within `MWProtocolLayer.readTimeout`
    /// (default 5 seconds). Usually indicates the BLE link is degraded or the
    /// board is not responding to the requested register.
    case timeout
}

// `LocalizedError` makes `error.localizedDescription` emit the human-readable
// strings below instead of the Foundation-synthesized fallback. The
// `operationFailed` / `invalidState` prefixes match the legacy Combine SDK
// (MWError.swift) verbatim — tests that assert on the user-visible message
// rely on that parity (e.g. the BMI270 orientation chip-guard diagnostic).
extension MWError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnsupported:    return "Bluetooth unsupported on this platform"
        case .bluetoothUnauthorized:   return "Bluetooth unauthorized in this App"
        case .bluetoothPoweredOff:     return "Bluetooth powered off"
        case .operationFailed(let m):  return "Operation failed: \(m)"
        case .invalidState(let m):     return "Invalid state: \(m)"
        case .timeout:                 return "Operation timed out"
        }
    }
}
