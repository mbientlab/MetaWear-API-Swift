import Foundation

nonisolated enum ExportFilename {

    static func make(deviceName: String, sensorKind: String, date: Date = .now) -> String {
        let device = sanitize(deviceName.isEmpty ? "MetaWear" : deviceName)
        let sensor = sanitize(sensorKind)
        let stamp = date.formatted(isoStyle).replacing(":", with: "-")
        return "\(device)-\(sensor)-\(stamp).csv"
    }

    private static let isoStyle = Date.ISO8601FormatStyle()
        .year().month().day()
        .time(includingFractionalSeconds: false)
        .dateSeparator(.dash)
        .timeSeparator(.colon)

    private static func sanitize(_ raw: String) -> String {
        raw.replacing(/[^A-Za-z0-9_-]/, with: "")
    }
}
