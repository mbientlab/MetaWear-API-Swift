import MetaWear

/// A sensor sample type that can be stored in and reconstructed from `MWSampleRecord`.
///
/// Retroactive conformances for all SDK types live in `MWPersistableConformances.swift`
/// in this target. Adding support for a new sensor type means:
/// 1. Add the Swift struct to `MWTypes.swift` in the core SDK.
/// 2. Add one `extension NewType: @retroactive MWPersistable` block here.
public protocol MWPersistable: MWDataConvertible, Sendable {

    /// String stored in `MWSessionRecord.sensorKind`.
    static var persistenceKind: String { get }

    /// Pack this sample into the flat (f0–f3, accuracy) layout used by `MWSampleRecord`.
    var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) { get }

    /// Reconstruct a sample from the flat layout.
    static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> Self
}
