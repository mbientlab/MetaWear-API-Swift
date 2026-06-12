import SwiftData
import Foundation

/// A single download session for one sensor on one device.
///
/// One `MWSessionRecord` is created each time `downloadLogs` completes.
/// Its `samples` relationship is cascade-deleted when the session is removed.
@Model
public final class MWSessionRecord {

    /// Stable, app-assigned session identifier. Use this for all cross-context lookups.
    @Attribute(.unique) public var id: UUID
    /// The CoreBluetooth peripheral UUID of the source device.
    public var deviceID: UUID
    /// Discriminator matching `MWPersistable.persistenceKind`
    /// (e.g. "cartesian", "quaternion", "euler", "float", …).
    public var sensorKind: String
    /// Wall-clock timestamp of the first sample.
    public var startDate: Date
    /// Wall-clock timestamp of the last sample.
    public var endDate: Date
    /// Denormalised device info — stored once per session for offline display.
    public var deviceSerial: String
    public var deviceModel: String
    public var deviceFirmware: String
    /// User-facing description of the sensor + settings the session
    /// captured (e.g. "Gyroscope · ±2000 dps · 25 Hz"). Optional because
    /// `sensorKind` alone is enough to load the samples; this is a display
    /// hint for the history list. Nil on records written before this
    /// field was added.
    public var label: String?

    @Relationship(deleteRule: .cascade, inverse: \MWSampleRecord.session)
    public var samples: [MWSampleRecord]

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        sensorKind: String,
        startDate: Date,
        endDate: Date,
        deviceSerial: String,
        deviceModel: String,
        deviceFirmware: String,
        label: String? = nil
    ) {
        self.id             = id
        self.deviceID       = deviceID
        self.sensorKind     = sensorKind
        self.startDate      = startDate
        self.endDate        = endDate
        self.deviceSerial   = deviceSerial
        self.deviceModel    = deviceModel
        self.deviceFirmware = deviceFirmware
        self.label          = label
        self.samples        = []
    }
}
