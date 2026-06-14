import Foundation
import MetaWear
import MetaWearPersistence

enum CSVExporter {

    static func exportToTempFile(
        store: MWPersistenceStore,
        snapshot: MWSessionSnapshot,
        deviceName: String? = nil
    ) async throws -> URL {
        let table = try await table(for: snapshot, store: store)
        // Use the same short sensor tag the streaming exporter uses (e.g.
        // "accel", "gyro", "fusion-quat") so files saved from logged
        // sessions sit alongside live-stream exports with a consistent
        // naming convention. Falls back to the persistence-kind
        // discriminator ("cartesian", etc.) when the snapshot predates the
        // rich label and we can't derive a sensor-specific tag.
        let tag = streamingTag(forLabel: snapshot.label) ?? snapshot.sensorKind
        let filename = ExportFilename.make(
            deviceName: deviceName ?? snapshot.deviceModel,
            sensorKind: tag,
            date: snapshot.startDate
        )
        let url = URL.temporaryDirectory.appending(path: filename)
        try table.writeCSV(to: url)
        return url
    }

    /// Map a `MWSessionSnapshot.label` (e.g. "Gyroscope · ±2000 dps · 25 Hz",
    /// "Fusion · Quaternion · 100 Hz") back to the short sensor tag the
    /// live-stream exporter uses (e.g. "gyro", "fusion-quat"). Returns nil
    /// for labels that don't start with a known sensor display name; the
    /// caller falls back to `sensorKind` in that case.
    private static func streamingTag(forLabel label: String?) -> String? {
        guard let parts = label?.components(separatedBy: " · "), let head = parts.first else {
            return nil
        }
        switch head {
        case "Accelerometer": return "accel"
        case "Gyroscope":     return "gyro"
        case "Magnetometer":  return "mag"
        case "Barometer":     return "baro"
        case "Temperature":   return "temp"
        case "Humidity":      return "humidity"
        case "Ambient Light": return "light"
        case "Fusion":
            switch parts.count > 1 ? parts[1] : "" {
            case "Quaternion":                  return "fusion-quat"
            case "Euler Angles":                return "fusion-euler"
            case "Linear Acceleration":         return "fusion-linacc"
            case "Gravity":                     return "fusion-gravity"
            case "Corrected Acceleration":      return "fusion-cacc"
            case "Corrected Angular Velocity":  return "fusion-cgyro"
            case "Corrected Magnetic Field":    return "fusion-cmag"
            default:                            return "fusion"
            }
        default: return nil
        }
    }

    private static func table(for snapshot: MWSessionSnapshot, store: MWPersistenceStore) async throws -> MWDataTable {
        switch snapshot.sensorKind {
        case CartesianFloat.persistenceKind:
            return try await store.exportTable(sessionID: snapshot.id, as: CartesianFloat.self)
        case Quaternion.persistenceKind:
            return try await store.exportTable(sessionID: snapshot.id, as: Quaternion.self)
        case EulerAngles.persistenceKind:
            return try await store.exportTable(sessionID: snapshot.id, as: EulerAngles.self)
        case CorrectedCartesianFloat.persistenceKind:
            return try await store.exportTable(sessionID: snapshot.id, as: CorrectedCartesianFloat.self)
        case Float.persistenceKind:
            return try await store.exportTable(sessionID: snapshot.id, as: Float.self)
        case Bool.persistenceKind:
            return try await store.exportTable(sessionID: snapshot.id, as: Bool.self)
        default:
            throw MWPersistenceError.kindMismatch(stored: snapshot.sensorKind, requested: "unsupported")
        }
    }
}
