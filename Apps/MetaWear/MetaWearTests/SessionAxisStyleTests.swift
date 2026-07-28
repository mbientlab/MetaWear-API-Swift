import Testing
import Foundation
import MetaWear
import MetaWearPersistence
@testable import MetaWearApp

/// Saved-session charts used to fall back to generic x/y/z/w labels for
/// everything — which MISLABELED fusion data (a quaternion's first channel
/// is w, Euler's are heading/pitch/roll/yaw). These pin the recovery of the
/// real sensor style from the persisted kind + capture-time label.
@MainActor
struct SessionAxisStyleTests {

    @Test func quaternionKind_labelsWxyzInOrder() {
        let style = SensorAxisStyle.forSession(
            sensorKind: Quaternion.persistenceKind, label: nil, channelCount: 4)
        #expect(style.channels.map(\.id) == ["w", "x", "y", "z"])
    }

    @Test func eulerKind_labelsEulerChannels() {
        let style = SensorAxisStyle.forSession(
            sensorKind: EulerAngles.persistenceKind, label: nil, channelCount: 4)
        #expect(style.channels.map(\.id) == ["heading", "pitch", "roll", "yaw"])
        #expect(style.unit == "°")
    }

    @Test func gyroLabel_restoresUnitAndCapturedRange() {
        let style = SensorAxisStyle.forSession(
            sensorKind: CartesianFloat.persistenceKind,
            label: "Gyroscope · ±500 dps · 25 Hz", channelCount: 3)
        #expect(style.unit == "dps")
        #expect(style.yRange == -500...500)
        #expect(style.channels.map(\.id) == ["x", "y", "z"])
    }

    @Test func accelLabel_withoutRangeChunk_usesSensorDefault() {
        let style = SensorAxisStyle.forSession(
            sensorKind: CartesianFloat.persistenceKind,
            label: "Accelerometer · 50 Hz", channelCount: 3)
        #expect(style.unit == "g")
    }

    @Test func fusionGravityLabel_resolvesFusionOutput() {
        let style = SensorAxisStyle.forSession(
            sensorKind: CartesianFloat.persistenceKind,
            label: "Fusion · Gravity · 100 Hz", channelCount: 3)
        #expect(style.unit == "g")
        #expect(style.yRange == -1...1)
    }

    @Test func temperatureLabel_resolvesScalarStyle() {
        let style = SensorAxisStyle.forSession(
            sensorKind: Float.persistenceKind,
            label: "Temperature · 1 Hz", channelCount: 1)
        #expect(style.unit == "°C")
    }

    @Test func unknownLabelAndKind_fallsBackToGeneric() {
        let style = SensorAxisStyle.forSession(
            sensorKind: "cartesian", label: "Mystery Sensor · 1 Hz", channelCount: 3)
        #expect(style.channels.map(\.id) == ["x", "y", "z"])
        #expect(style.unit.isEmpty)
    }

    @Test func legacyRecordWithNilLabel_fallsBackToGeneric() {
        let style = SensorAxisStyle.forSession(
            sensorKind: "cartesian", label: nil, channelCount: 3)
        #expect(style.channels.count == 3)
    }
}
