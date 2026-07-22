import SwiftUI
import MetaWear
import MetaWearPersistence

extension SensorAxisStyle {
    /// Resolve the chart style for a SAVED session from its persisted
    /// discriminators. The old `.generic(channelCount:)` fallback actively
    /// mislabeled fusion sessions — a quaternion's first channel is `w`, not
    /// `x`, and Euler channels are heading/pitch/roll/yaw — so fusion kinds
    /// resolve from the type discriminator alone, and everything else tries
    /// to recover the real sensor (units, colors, captured ± range) from the
    /// rich label stamped at capture time.
    static func forSession(sensorKind: String, label: String?, channelCount: Int) -> SensorAxisStyle {
        if sensorKind == Quaternion.persistenceKind {
            return SensorKey.sensorFusion(.quaternion).axisStyle
        }
        if sensorKind == EulerAngles.persistenceKind {
            return SensorKey.sensorFusion(.eulerAngles).axisStyle
        }
        if let style = styleFromLabel(label) {
            return style
        }
        return .generic(channelCount: channelCount)
    }

    /// Map a capture-time label ("Gyroscope · ±500 dps · 25 Hz",
    /// "Fusion · Gravity · 100 Hz") back to its sensor's style. Returns nil
    /// for legacy records without a label or with an unrecognized head.
    private static func styleFromLabel(_ label: String?) -> SensorAxisStyle? {
        guard let parts = label?.components(separatedBy: " · "), let head = parts.first else {
            return nil
        }
        let key: SensorKey?
        switch head {
        case "Accelerometer": key = .accelerometer
        case "Gyroscope":     key = .gyroscope
        case "Magnetometer":  key = .magnetometer
        case "Barometer":     key = .barometer
        case "Temperature":   key = .temperature
        case "Humidity":      key = .humidity
        case "Ambient Light": key = .ambientLight
        case "Fusion":
            let outputName = parts.count > 1 ? parts[1] : ""
            key = SensorFusionOutput.allCases
                .first { $0.displayName == outputName }
                .map(SensorKey.sensorFusion)
        default: key = nil
        }
        guard let key else { return nil }
        let base = key.axisStyle
        // Restore the full-scale range the session was captured at ("±500 dps"
        // → y-range −500…500) so the trace sits in its real frame instead of
        // the sensor's default.
        if let rangePart = parts.first(where: { $0.hasPrefix("±") }),
           let magnitude = rangePart.dropFirst().components(separatedBy: " ").first,
           let value = Double(magnitude) {
            return SensorAxisStyle(unit: base.unit, yRange: -value...value, channels: base.channels)
        }
        return base
    }
}
