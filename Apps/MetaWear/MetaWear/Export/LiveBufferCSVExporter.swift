import Foundation

nonisolated enum LiveBufferCSVExporter {

    /// Sample data already detached from its Channel (which is `@MainActor`)
    /// so the file write can run on a background task without crossing the
    /// actor barrier.
    struct ChannelSnapshot: Sendable {
        let key: SensorKey
        let displayName: String
        let channelLabels: [String]
        let samples: [AnyChartSample]
    }

    /// Write one CSV per non-empty snapshot to a temp file. Safe to call off
    /// the main actor — the snapshots are value-typed and self-contained.
    /// Returns one `ExportSheetItem` per file actually written; empty
    /// snapshots and failed writes are skipped silently.
    static func write(snapshots: [ChannelSnapshot], deviceName: String) -> [ExportSheetItem] {
        var items: [ExportSheetItem] = []
        let now = Date.now
        print("[Export] snapshots=\(snapshots.count) device=\(deviceName)")
        for snapshot in snapshots {
            print("[Export]   \(snapshot.key) samples=\(snapshot.samples.count)")
            guard !snapshot.samples.isEmpty else { continue }
            let csv = makeCSV(snapshot: snapshot)
            let filename = ExportFilename.make(
                deviceName: deviceName,
                sensorKind: sensorTag(for: snapshot.key),
                date: now
            )
            let url = URL.temporaryDirectory.appending(path: filename)
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                print("[Export]   wrote \(url.lastPathComponent) (\(csv.utf8.count) bytes)")
                items.append(ExportSheetItem(
                    url: url,
                    subtitle: "\(snapshot.samples.count) samples · \(snapshot.displayName)"
                ))
            } catch {
                print("[Export]   FAILED \(url.path): \(error)")
                continue
            }
        }
        print("[Export] done — \(items.count) file(s)")
        return items
    }

    private static func makeCSV(snapshot: ChannelSnapshot) -> String {
        let labels = snapshot.channelLabels
        let channelCount = labels.count
        var lines: [String] = []
        lines.reserveCapacity(snapshot.samples.count + 1)
        lines.append((["time"] + labels).joined(separator: ","))
        for s in snapshot.samples {
            var fields: [String] = [iso(s.time)]
            if channelCount > 0 { fields.append(format(s.f0)) }
            if channelCount > 1 { fields.append(format(s.f1)) }
            if channelCount > 2 { fields.append(format(s.f2)) }
            if channelCount > 3 { fields.append(format(s.f3)) }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Filename-safe sensor tag so the export looks consistent with logged
    /// sessions (which use `sensorKind` strings).
    private static func sensorTag(for key: SensorKey) -> String {
        switch key {
        case .accelerometer:                          return "accel"
        case .gyroscope:                              return "gyro"
        case .magnetometer:                           return "mag"
        case .barometer:                              return "baro"
        case .temperature:                            return "temp"
        case .humidity:                               return "humidity"
        case .ambientLight:                           return "light"
        case .sensorFusion(.quaternion):              return "fusion-quat"
        case .sensorFusion(.eulerAngles):             return "fusion-euler"
        case .sensorFusion(.gravity):                 return "fusion-gravity"
        case .sensorFusion(.linearAcceleration):      return "fusion-linacc"
        case .sensorFusion(.correctedAcceleration):   return "fusion-cacc"
        case .sensorFusion(.correctedAngularVelocity):return "fusion-cgyro"
        case .sensorFusion(.correctedMagneticField):  return "fusion-cmag"
        }
    }

    private static let isoStyle = Date.ISO8601FormatStyle()
        .year().month().day()
        .dateSeparator(.dash)
        .timeSeparator(.colon)
        .time(includingFractionalSeconds: true)

    private static func iso(_ date: Date) -> String { date.formatted(isoStyle) }

    private static func format(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }
}
