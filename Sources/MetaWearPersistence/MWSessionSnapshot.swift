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
    /// Display name of the board at capture time. Nil on records written
    /// before the field existed — fall back to `deviceSerial`/`deviceModel`.
    public let deviceName: String?
    /// Group-capture batch, when several boards were logged together.
    public let groupID: UUID?

    /// Memberwise initializer — for previews and tests; production
    /// snapshots come from `init(record:)`.
    public init(
        id: UUID = UUID(), deviceID: UUID = UUID(), sensorKind: String,
        startDate: Date, endDate: Date, sampleCount: Int,
        deviceSerial: String, deviceModel: String = "", deviceFirmware: String = "",
        label: String? = nil, deviceName: String? = nil, groupID: UUID? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.sensorKind = sensorKind
        self.startDate = startDate
        self.endDate = endDate
        self.sampleCount = sampleCount
        self.deviceSerial = deviceSerial
        self.deviceModel = deviceModel
        self.deviceFirmware = deviceFirmware
        self.label = label
        self.deviceName = deviceName
        self.groupID = groupID
    }

    init(record: MWSessionRecord) {
        self.id             = record.id
        self.deviceID       = record.deviceID
        self.sensorKind     = record.sensorKind
        self.startDate      = record.startDate
        self.endDate        = record.endDate
        // Prefer the denormalised count; pre-migration records carry 0 and
        // fall back to counting the (prefetched) relationship.
        self.sampleCount    = record.sampleCount > 0
            ? record.sampleCount
            : (record.samples?.count ?? 0)
        self.deviceSerial   = record.deviceSerial
        self.deviceModel    = record.deviceModel
        self.deviceFirmware = record.deviceFirmware
        self.label          = record.label
        self.deviceName     = record.deviceName
        self.groupID        = record.groupID
    }
}
