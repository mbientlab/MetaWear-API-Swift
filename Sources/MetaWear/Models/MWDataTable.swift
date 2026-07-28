import Foundation

// MARK: - CSV formatting helpers
//
// CSV byte-stability matters: tools that consume our exports parse the columns
// numerically, and a locale-dependent decimal separator (`1,000000` instead of
// `1.000000`) would silently corrupt downstream analysis. We pin the format to
// POSIX locale with no thousands grouping so the wire output is byte-for-byte
// identical regardless of the host's region settings.

private let posixLocale = Locale(identifier: "en_US_POSIX")

/// Six-decimal CSV format for `Float`: matches the legacy `String(format: "%.6f", _)` output.
private let csv6Float: FloatingPointFormatStyle<Float> =
    .number.precision(.fractionLength(6)).grouping(.never).locale(posixLocale)

/// Four-decimal CSV format for `Float`: matches the legacy `String(format: "%.4f", _)` output.
private let csv4Float: FloatingPointFormatStyle<Float> =
    .number.precision(.fractionLength(4)).grouping(.never).locale(posixLocale)

/// Three-decimal CSV format for `Double`: matches the legacy `String(format: "%.3f", _)` output.
private let csv3Double: FloatingPointFormatStyle<Double> =
    .number.precision(.fractionLength(3)).grouping(.never).locale(posixLocale)

// MARK: - MWDataConvertible

/// A sensor sample type that can express itself as named string columns for CSV export.
public protocol MWDataConvertible: Sendable {
    /// Column header names for the sensor-specific fields (excludes timestamp columns).
    static var columnHeaders: [String] { get }
    /// String representation of each sensor-specific field, in the same order as `columnHeaders`.
    var columnValues: [String] { get }
    /// Headers for host-computed convenience columns appended AFTER the raw
    /// fields (e.g. Euler angles derived from a quaternion). Deriving at
    /// export keeps the stored samples raw while sparing spreadsheet users
    /// the quaternion math. Empty for types with nothing to derive.
    static var derivedColumnHeaders: [String] { get }
    /// Values parallel to `derivedColumnHeaders`.
    var derivedColumnValues: [String] { get }
}

public extension MWDataConvertible {
    static var derivedColumnHeaders: [String] { [] }
    var derivedColumnValues: [String] { [] }
}

// MARK: - Conformances

extension CartesianFloat: MWDataConvertible {
    public static var columnHeaders: [String] { ["x", "y", "z"] }
    public var columnValues: [String] {
        [x.formatted(csv6Float), y.formatted(csv6Float), z.formatted(csv6Float)]
    }
}

extension Quaternion: MWDataConvertible {
    public static var columnHeaders: [String] { ["w", "x", "y", "z"] }
    public var columnValues: [String] {
        [w.formatted(csv6Float), x.formatted(csv6Float),
         y.formatted(csv6Float), z.formatted(csv6Float)]
    }
    public static var derivedColumnHeaders: [String] { ["heading", "pitch", "roll"] }
    public var derivedColumnValues: [String] {
        let e = derivedEulerAngles
        return [e.heading.formatted(csv4Float),
                e.pitch.formatted(csv4Float),
                e.roll.formatted(csv4Float)]
    }
}

public extension Quaternion {
    /// Euler angles computed from this quaternion (Tait-Bryan, degrees):
    /// heading normalized to 0..360°, pitch −90..+90°, roll −180..+180°.
    ///
    /// Axis convention established EMPIRICALLY on hardware (fw 1.7.x NDoF):
    /// the board's vertical axis lives in the quaternion's `x` component,
    /// with the lateral (pitch) axis in `z` and the longitudinal (roll)
    /// axis in `y` — verified with axis-isolated motions on a real board,
    /// against docs that imply a Z-up frame. The formulas below are the
    /// standard ZYX derivation with components relabeled to that frame.
    ///
    /// `yaw` is set equal to `heading`: the firmware's separate yaw channel is
    /// gyroscope-INTEGRATED (unbounded, drifts) and cannot be reconstructed
    /// from a single orientation quaternion. No derived-yaw CSV column is
    /// emitted for the same reason — it would just duplicate heading.
    var derivedEulerAngles: EulerAngles {
        let w = Double(w), x = Double(x), y = Double(y), z = Double(z)
        let roll  = atan2(2 * (w * y + z * x), 1 - 2 * (y * y + z * z))
        let pitch = asin(min(1, max(-1, 2 * (w * z - x * y))))
        let yaw   = atan2(2 * (w * x + y * z), 1 - 2 * (z * z + x * x))
        var heading = yaw * 180 / .pi
        if heading < 0 { heading += 360 }
        return EulerAngles(heading: Float(heading),
                           pitch:   Float(pitch * 180 / .pi),
                           roll:    Float(roll * 180 / .pi),
                           yaw:     Float(heading))
    }
}

extension EulerAngles: MWDataConvertible {
    public static var columnHeaders: [String] { ["heading", "pitch", "roll", "yaw"] }
    public var columnValues: [String] {
        [heading.formatted(csv4Float), pitch.formatted(csv4Float),
         roll.formatted(csv4Float),    yaw.formatted(csv4Float)]
    }
}

extension CorrectedCartesianFloat: MWDataConvertible {
    public static var columnHeaders: [String] { ["x", "y", "z", "accuracy"] }
    public var columnValues: [String] {
        [x.formatted(csv6Float), y.formatted(csv6Float),
         z.formatted(csv6Float), "\(accuracy)"]
    }
}

extension Float: MWDataConvertible {
    public static var columnHeaders: [String] { ["value"] }
    public var columnValues: [String] { [self.formatted(csv6Float)] }
}

extension Bool: MWDataConvertible {
    public static var columnHeaders: [String] { ["value"] }
    public var columnValues: [String] { [self ? "1" : "0"] }
}

// MARK: - MWDataTable

/// A named table of string rows suitable for CSV export.
public struct MWDataTable: Sendable {
    /// Logical name for the table (typically the sensor key, e.g. `"acceleration"`).
    public let name: String
    /// Column header strings, in order.
    public let columns: [String]
    /// Data rows, each as an array of strings parallel to `columns`.
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
        let columns = ["epoch", "elapsed_ms"] + S.columnHeaders + S.derivedColumnHeaders
        let rows = samples.map { s -> [String] in
            [iso.string(from: s.date), s.tickMs.formatted(csv3Double)]
                + s.value.columnValues + s.value.derivedColumnValues
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
        let columns = ["epoch"] + S.columnHeaders + S.derivedColumnHeaders
        let rows = samples.map { s -> [String] in
            [iso.string(from: s.time)] + s.value.columnValues + s.value.derivedColumnValues
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
