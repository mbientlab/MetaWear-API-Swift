import Foundation

nonisolated enum ExportFilename {

    static func make(deviceName: String, sensorKind: String, date: Date = .now,
                     discriminator: String? = nil) -> String {
        let device = sanitize(deviceName.isEmpty ? "MetaWear" : deviceName)
        let sensor = sanitize(sensorKind)
        let stamp = date.formatted(isoStyle).replacing(":", with: "-")
        // The discriminator (short session-UUID prefix) makes filenames
        // collision-proof: with several boards, two same-named boards can
        // finish downloads in the same second, and temp-file writes
        // OVERWRITE silently on a name match.
        let suffix = discriminator.map { "-" + sanitize($0) } ?? ""
        return "\(device)-\(sensor)-\(stamp)\(suffix).csv"
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
