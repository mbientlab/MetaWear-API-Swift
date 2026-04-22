import Foundation

// MARK: - MWDataConvertible

/// A sensor sample type that can express itself as named string columns for CSV export.
public protocol MWDataConvertible: Sendable {
    /// Column header names for the sensor-specific fields (excludes timestamp columns).
    static var columnHeaders: [String] { get }
    /// String representation of each sensor-specific field, in the same order as `columnHeaders`.
    var columnValues: [String] { get }
}

// MARK: - Conformances

extension CartesianFloat: MWDataConvertible {
    public static var columnHeaders: [String] { ["x", "y", "z"] }
    public var columnValues: [String] {
        [String(format: "%.6f", x), String(format: "%.6f", y), String(format: "%.6f", z)]
    }
}

extension Quaternion: MWDataConvertible {
    public static var columnHeaders: [String] { ["w", "x", "y", "z"] }
    public var columnValues: [String] {
        [String(format: "%.6f", w), String(format: "%.6f", x),
         String(format: "%.6f", y), String(format: "%.6f", z)]
    }
}

extension EulerAngles: MWDataConvertible {
    public static var columnHeaders: [String] { ["heading", "pitch", "roll", "yaw"] }
    public var columnValues: [String] {
        [String(format: "%.4f", heading), String(format: "%.4f", pitch),
         String(format: "%.4f", roll),    String(format: "%.4f", yaw)]
    }
}

extension CorrectedCartesianFloat: MWDataConvertible {
    public static var columnHeaders: [String] { ["x", "y", "z", "accuracy"] }
    public var columnValues: [String] {
        [String(format: "%.6f", x), String(format: "%.6f", y),
         String(format: "%.6f", z), "\(accuracy)"]
    }
}

extension Float: MWDataConvertible {
    public static var columnHeaders: [String] { ["value"] }
    public var columnValues: [String] { [String(format: "%.6f", self)] }
}

extension Bool: MWDataConvertible {
    public static var columnHeaders: [String] { ["value"] }
    public var columnValues: [String] { [self ? "1" : "0"] }
}

// MARK: - MWDataTable

/// A named table of string rows suitable for CSV export.
public struct MWDataTable: Sendable {
    public let name: String
    public let columns: [String]
    public let rows: [[String]]

    public init(name: String, columns: [String], rows: [[String]]) {
        self.name    = name
        self.columns = columns
        self.rows    = rows
    }
}

// MARK: - Factory methods

public extension MWDataTable {

    /// Build a table from typed logged samples.
    /// Columns: epoch (ISO 8601), elapsed_ms, then sensor-specific columns.
    static func from<S: MWDataConvertible>(
        logged samples: [MWLoggedSample<S>],
        name: String
    ) -> MWDataTable {
        let iso = ISO8601DateFormatter()
        let columns = ["epoch", "elapsed_ms"] + S.columnHeaders
        let rows = samples.map { s -> [String] in
            [iso.string(from: s.date), String(format: "%.3f", s.tickMs)] + s.value.columnValues
        }
        return MWDataTable(name: name, columns: columns, rows: rows)
    }

    /// Build a table from a streamed sample array.
    /// Columns: epoch (ISO 8601), then sensor-specific columns.
    static func from<S: MWDataConvertible>(
        streamed samples: [Timestamped<S>],
        name: String
    ) -> MWDataTable {
        let iso = ISO8601DateFormatter()
        let columns = ["epoch"] + S.columnHeaders
        let rows = samples.map { s -> [String] in
            [iso.string(from: s.time)] + s.value.columnValues
        }
        return MWDataTable(name: name, columns: columns, rows: rows)
    }
}

// MARK: - CSV export

public extension MWDataTable {

    /// The table rendered as a CSV string (header row + one row per sample).
    var csvString: String {
        var lines: [String] = [columns.joined(separator: ",")]
        for row in rows {
            lines.append(row.map { field in
                // Quote fields that contain commas or quotes
                if field.contains(",") || field.contains("\"") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Write the CSV to a file URL.
    func writeCSV(to url: URL) throws {
        try csvString.write(to: url, atomically: true, encoding: .utf8)
    }
}
