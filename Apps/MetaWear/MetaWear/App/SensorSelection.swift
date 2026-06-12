import Foundation
import SwiftUI
import MetaWear

enum SensorKey: Hashable, Sendable {
    case accelerometer
    case gyroscope
    case magnetometer
    case sensorFusion(SensorFusionOutput)
    case barometer
    case temperature
    case humidity
    case ambientLight

    /// Coarse classification ignoring `sensorFusion`'s associated value.
    /// Lets screens declare which sensor families they support (e.g. Logging
    /// can't handle temp/humidity/ambient light, which aren't natively
    /// loggable on the board).
    enum Kind: Hashable, CaseIterable, Sendable {
        case accelerometer
        case gyroscope
        case magnetometer
        case sensorFusion
        case barometer
        case temperature
        case humidity
        case ambientLight
    }

    var kind: Kind {
        switch self {
        case .accelerometer: return .accelerometer
        case .gyroscope:     return .gyroscope
        case .magnetometer:  return .magnetometer
        case .sensorFusion:  return .sensorFusion
        case .barometer:     return .barometer
        case .temperature:   return .temperature
        case .humidity:      return .humidity
        case .ambientLight:  return .ambientLight
        }
    }

    /// Stable string identifier used when persisting a `SensorKey` to
    /// SwiftData (e.g. `LogSessionRecord.sensorKind`). Mirrors what we use
    /// in CSV filenames — short, lowercase, hyphenated for fusion outputs.
    var persistenceKey: String {
        switch self {
        case .accelerometer:          return "accelerometer"
        case .gyroscope:              return "gyroscope"
        case .magnetometer:           return "magnetometer"
        case .barometer:              return "barometer"
        case .temperature:            return "temperature"
        case .humidity:               return "humidity"
        case .ambientLight:           return "ambientLight"
        case .sensorFusion(let out):  return "fusion-\(out.rawValue)"
        }
    }

    init?(persistenceKey: String) {
        switch persistenceKey {
        case "accelerometer": self = .accelerometer
        case "gyroscope":     self = .gyroscope
        case "magnetometer":  self = .magnetometer
        case "barometer":     self = .barometer
        case "temperature":   self = .temperature
        case "humidity":      self = .humidity
        case "ambientLight":  self = .ambientLight
        default:
            let prefix = "fusion-"
            guard persistenceKey.hasPrefix(prefix),
                  let out = SensorFusionOutput(rawValue: String(persistenceKey.dropFirst(prefix.count)))
            else { return nil }
            self = .sensorFusion(out)
        }
    }
}

enum SensorFusionOutput: String, CaseIterable, Sendable, Identifiable {
    case quaternion
    case eulerAngles
    case linearAcceleration
    case gravity
    case correctedAcceleration
    case correctedAngularVelocity
    case correctedMagneticField

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quaternion:               "Quaternion"
        case .eulerAngles:              "Euler Angles"
        case .linearAcceleration:       "Linear Acceleration"
        case .gravity:                  "Gravity"
        case .correctedAcceleration:    "Corrected Acceleration"
        case .correctedAngularVelocity: "Corrected Angular Velocity"
        case .correctedMagneticField:   "Corrected Magnetic Field"
        }
    }
}

enum SensorFusionMode: String, CaseIterable, Sendable, Identifiable {
    case ndof = "NDoF"
    case imuPlus = "IMU Plus"
    case compass = "Compass"
    case m4g = "M4G"

    var id: String { rawValue }
}

struct SensorSelection: Identifiable, Sendable, Hashable {
    let id: SensorKey
    var hz: Double
    /// Sensor-specific full-scale range. For accelerometer this is the
    /// ± g value (2, 4, 8, 16); for gyroscope it is the ± dps value
    /// (125, 250, 500, 1000, 2000). `nil` for sensors without a range
    /// concept (mag, baro, temp, humidity, ambient light, fusion).
    var range: Int?
    /// Sub-channel index for sensors that expose multiple sources from one
    /// module. Currently only used by temperature (multi-channel BME280 /
    /// thermistor / NRF die layout on RPro/MMS boards). `nil` means
    /// channel 0 — the NRF die, which is always present.
    var channel: Int?

    var displayName: String {
        switch id {
        case .accelerometer:    "Accelerometer"
        case .gyroscope:        "Gyroscope"
        case .magnetometer:     "Magnetometer"
        case .sensorFusion(let out): "Fusion · \(out.displayName)"
        case .barometer:        "Barometer"
        case .temperature:      "Temperature"
        case .humidity:         "Humidity"
        case .ambientLight:     "Ambient Light"
        }
    }

    var systemImage: String {
        switch id {
        case .accelerometer:    "move.3d"
        case .gyroscope:        "gyroscope"
        case .magnetometer:     "location.north.circle"
        case .sensorFusion:     "cube.transparent"
        case .barometer:        "barometer"
        case .temperature:      "thermometer.medium"
        case .humidity:         "humidity"
        case .ambientLight:     "sun.max"
        }
    }
}

// MARK: - Chart axis style

/// How a sensor's samples should be plotted: unit label for the y-axis, an
/// optional fixed y-range so the trace doesn't auto-rescale on every redraw,
/// and the per-channel display labels + colors used by both the series legend
/// and the line tints.
struct SensorAxisStyle {
    struct Channel: Identifiable, Hashable {
        let id: String
        let color: Color
    }

    let unit: String
    let yRange: ClosedRange<Double>?
    let channels: [Channel]

    var styleScale: KeyValuePairs<String, Color> {
        // KeyValuePairs is not constructible from an array literal at runtime,
        // so the caller passes the explicit pairs. Up to 4 channels.
        switch channels.count {
        case 1: return [channels[0].id: channels[0].color]
        case 2: return [channels[0].id: channels[0].color, channels[1].id: channels[1].color]
        case 3: return [channels[0].id: channels[0].color, channels[1].id: channels[1].color, channels[2].id: channels[2].color]
        case 4: return [channels[0].id: channels[0].color, channels[1].id: channels[1].color, channels[2].id: channels[2].color, channels[3].id: channels[3].color]
        default: return [:]
        }
    }
}

extension SensorKey {
    /// Discrete range options for sensors that have a configurable full-scale.
    /// The unit is implied by the sensor: g for accelerometer, dps for gyro.
    /// Returns `nil` when the sensor has no range concept.
    var rangeOptions: [Int]? {
        switch self {
        case .accelerometer: return [2, 4, 8, 16]
        case .gyroscope:     return [125, 250, 500, 1000, 2000]
        default:             return nil
        }
    }

    /// Suffix appended to a Range picker's options ("g" or "dps").
    var rangeUnit: String? {
        switch self {
        case .accelerometer: return "g"
        case .gyroscope:     return "dps"
        default:             return nil
        }
    }

    /// Sensor-appropriate sample-rate options for the Rate picker. Fast IMU
    /// sensors expose hardware ODRs; poll-based readables (temperature,
    /// humidity) expose practical poll intervals; ambient light is bounded
    /// by the LTR329's own measurement-rate register.
    var rateOptions: [Double] {
        switch self {
        case .accelerometer, .gyroscope:    return [12.5, 25, 50, 100, 200]
        case .magnetometer:                 return [10, 15, 20, 25, 30]
        case .barometer:                    return [5, 10, 25]
        case .temperature:                  return [0.5, 1, 2, 5]
        case .humidity:                     return [0.5, 1, 2, 5]
        case .ambientLight:                 return [2, 5, 10]
        case .sensorFusion:                 return [50, 100]
        }
    }

    /// Default Hz used when first adding this sensor — must appear in
    /// `rateOptions` so the Rate picker can render the selection.
    var defaultHz: Double {
        switch self {
        case .accelerometer, .gyroscope:    return 50
        case .magnetometer:                 return 25
        case .barometer:                    return 25
        case .temperature, .humidity:       return 1
        case .ambientLight:                 return 2
        case .sensorFusion:                 return 100
        }
    }

    /// MetaWear protocol module this sensor maps to. Used to look up
    /// presence in the connected device's discovered-module set so we can
    /// hide sensors the board doesn't physically carry (e.g. BME280 humidity
    /// on a MetaMotion S that only has IMU sensors).
    var module: MWModule {
        switch self {
        case .accelerometer:    return .accelerometer
        case .gyroscope:        return .gyro
        case .magnetometer:     return .magnetometer
        case .sensorFusion:     return .sensorFusion
        case .barometer:        return .barometer
        case .temperature:      return .temperature
        case .humidity:         return .humidity
        case .ambientLight:     return .ambientLight
        }
    }
}

extension SensorSelection {
    /// Human-readable description of the sensor + its settings — used as
    /// the rich label on persisted sessions so Session History shows e.g.
    /// "Gyroscope · ±2000 dps · 25 Hz" instead of the bare type
    /// discriminator. Range chunk is omitted for sensors without a range
    /// concept (mag, baro, temp, etc.).
    var label: String {
        var parts: [String] = [displayName]
        if let range, let unit = id.rangeUnit {
            parts.append("±\(range) \(unit)")
        }
        let hzText = hz.formatted(.number.precision(.fractionLength(0...1)))
        parts.append("\(hzText) Hz")
        return parts.joined(separator: " · ")
    }

    /// Axis style for this selection, with the y-range derived from the
    /// chosen `range` (or the key's default style for sensors without a
    /// configurable range).
    var axisStyle: SensorAxisStyle {
        let base = id.axisStyle
        guard let range, let _ = id.rangeOptions else { return base }
        let bound = Double(range)
        return SensorAxisStyle(unit: base.unit, yRange: -bound...bound, channels: base.channels)
    }
}

/// One entry in the temperature module's discovered channel layout.
/// Wraps the raw `MWThermometerSource` from the SDK so the UI can render
/// human-readable labels without having to extend the SDK type.
struct TempChannel: Identifiable, Hashable, Sendable {
    let index: Int
    let source: MWThermometerSource

    var id: Int { index }

    var displayName: String {
        switch source {
        case .nrfDie:           return "NRF Die"
        case .extThermistor:    return "External Thermistor"
        case .presetThermistor: return "Preset Thermistor"
        case .bmp280:           return "BMP280"
        case .invalid:          return "Channel \(index)"
        }
    }

    init?(index: Int, rawSource: UInt8) {
        guard let source = MWThermometerSource(rawValue: Int8(bitPattern: rawSource)),
              source != .invalid else { return nil }
        self.index = index
        self.source = source
    }
}

extension SensorAxisStyle {
    /// Fallback style derived only from channel count — used by historical
    /// session previews that have lost the original `SensorKey`. No unit
    /// label, auto y-range, generic x/y/z/w channel names.
    static func generic(channelCount: Int) -> SensorAxisStyle {
        let labels = ["x", "y", "z", "w"]
        let colors: [Color] = [.red, .green, .blue, .purple]
        let count = min(max(channelCount, 1), 4)
        let channels = (0..<count).map { Channel(id: labels[$0], color: colors[$0]) }
        return SensorAxisStyle(unit: "", yRange: nil, channels: channels)
    }
}

extension SensorKey {
    /// Default plotting style for this sensor: y-axis unit, sensible fixed
    /// range (when the hardware bounds it cleanly) and per-channel labels.
    var axisStyle: SensorAxisStyle {
        let xyz: [SensorAxisStyle.Channel] = [
            .init(id: "x", color: .red),
            .init(id: "y", color: .green),
            .init(id: "z", color: .blue)
        ]
        switch self {
        case .accelerometer:
            return SensorAxisStyle(unit: "g", yRange: -2...2, channels: xyz)
        case .gyroscope:
            return SensorAxisStyle(unit: "dps", yRange: -2000...2000, channels: xyz)
        case .magnetometer:
            return SensorAxisStyle(unit: "µT", yRange: nil, channels: xyz)
        case .barometer:
            return SensorAxisStyle(unit: "Pa", yRange: nil, channels: [
                .init(id: "pressure", color: Palette.accent)
            ])
        case .temperature:
            return SensorAxisStyle(unit: "°C", yRange: nil, channels: [
                .init(id: "°C", color: Palette.warning)
            ])
        case .humidity:
            return SensorAxisStyle(unit: "%", yRange: 0...100, channels: [
                .init(id: "%", color: Palette.info)
            ])
        case .ambientLight:
            return SensorAxisStyle(unit: "lx", yRange: nil, channels: [
                .init(id: "lux", color: Palette.warning)
            ])
        case .sensorFusion(.quaternion):
            return SensorAxisStyle(unit: "ratio", yRange: -1...1, channels: [
                .init(id: "w", color: .purple),
                .init(id: "x", color: .red),
                .init(id: "y", color: .green),
                .init(id: "z", color: .blue)
            ])
        case .sensorFusion(.eulerAngles):
            return SensorAxisStyle(unit: "°", yRange: -180...180, channels: [
                .init(id: "heading", color: .purple),
                .init(id: "pitch", color: .red),
                .init(id: "roll", color: .green),
                .init(id: "yaw", color: .blue)
            ])
        case .sensorFusion(.gravity):
            return SensorAxisStyle(unit: "g", yRange: -1...1, channels: xyz)
        case .sensorFusion(.linearAcceleration),
             .sensorFusion(.correctedAcceleration):
            return SensorAxisStyle(unit: "g", yRange: nil, channels: xyz)
        case .sensorFusion(.correctedAngularVelocity):
            return SensorAxisStyle(unit: "dps", yRange: nil, channels: xyz)
        case .sensorFusion(.correctedMagneticField):
            return SensorAxisStyle(unit: "µT", yRange: nil, channels: xyz)
        }
    }
}
