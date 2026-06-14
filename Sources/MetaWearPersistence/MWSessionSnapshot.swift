import Foundation

/// A `Sendable` value-type snapshot of an `MWSessionRecord`.
///
/// Returned from `MWPersistenceStore` fetch methods so callers outside the actor
/// can work with session metadata without holding a reference to the `@Model` object
/// or its `ModelContext`.
public struct MWSessionSnapshot: Sendable, Identifiable {
    /// Stable UUID assigned when the session was created.
    /// Pass this back to `MWPersistenceStore` methods that operate on a specific session.
    public let id: UUID
    /// CoreBluetooth peripheral UUID of the board that produced the samples.
    public let deviceID: UUID
    /// Discriminator matching `MWPersistable.persistenceKind`.
    public let sensorKind: String
    /// Wall-clock timestamp of the first sample in the session.
    public let startDate: Date
    /// Wall-clock timestamp of the last sample in the session.
    public let endDate: Date
    /// Number of persisted samples in the session.
    public let sampleCount: Int
    /// Device serial copied from the Device Information Service at capture time.
    public let deviceSerial: String
    /// Device model number copied from the Device Information Service.
    public let deviceModel: String
    /// Firmware revision copied from the Device Information Service.
    public let deviceFirmware: String
    /// User-facing sensor + settings string, e.g. "Gyroscope · ±2000 dps ·
    /// 25 Hz". Nil for older records persisted before the field existed —
    /// callers should fall back to `sensorKind` when nil.
    public let label: String?

    init(record: MWSessionRecord) {
        self.id             = record.id
        self.deviceID       = record.deviceID
        self.sensorKind     = record.sensorKind
        self.startDate      = record.startDate
        self.endDate        = record.endDate
        self.sampleCount    = record.samples?.count ?? 0
        self.deviceSerial   = record.deviceSerial
        self.deviceModel    = record.deviceModel
        self.deviceFirmware = record.deviceFirmware
        self.label          = record.label
    }
}
