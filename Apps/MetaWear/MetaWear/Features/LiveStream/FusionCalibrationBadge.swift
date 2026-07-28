import SwiftUI
import MetaWear

/// Compact readout of the fusion algorithm's per-sensor calibration accuracy,
/// with targeted coaching for whichever sensor is actually lagging.
///
/// Bosch's fusion outputs (especially heading) are unreliable until the
/// algorithm has calibrated itself against real motion, and nothing else in
/// the UI ever said so. Three chips — A(ccelerometer), G(yroscope),
/// M(agnetometer) — show the chip's own 0–3 accuracy report.
///
/// The bar is MEDIUM (≥ 2), not HIGH: Bosch's own guidance is that medium
/// accuracy is good enough to record. HIGH is a live trust score the
/// algorithm keeps re-evaluating — the magnetometer in particular gets
/// demoted the moment it detects field distortion (any desk full of
/// electronics), so "all green, forever" is not an achievable ask indoors
/// and the badge must not nag users toward it.
struct FusionCalibrationBadge: View {
    let calibration: MWSensorFusionCalibration

    /// Bosch's usability threshold — accuracy 2 (MEDIUM) of 0–3.
    private static let usableLevel: UInt8 = 2

    private enum Readiness {
        /// At least one sensor is below MEDIUM — orientation data is suspect.
        case calibrating
        /// Every sensor is at least MEDIUM — good enough to record.
        case ready
        /// Every sensor reads HIGH.
        case fullyCalibrated
    }

    private var readiness: Readiness {
        let levels = [calibration.accelerometer, calibration.gyroscope, calibration.magnetometer]
        if levels.allSatisfy({ $0 == 3 }) { return .fullyCalibrated }
        if levels.allSatisfy({ $0 >= Self.usableLevel }) { return .ready }
        return .calibrating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                switch readiness {
                case .calibrating:
                    Image(systemName: "scope").foregroundStyle(Palette.warning)
                    Text("Calibrating…").font(.subheadline.weight(.medium))
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.info)
                    Text("Ready To Record").font(.subheadline.weight(.medium))
                case .fullyCalibrated:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text("Fully Calibrated").font(.subheadline.weight(.medium))
                }
                Spacer()
                chip("A", level: calibration.accelerometer)
                chip("G", level: calibration.gyroscope)
                chip("M", level: calibration.magnetometer)
            }
            switch readiness {
            case .calibrating:
                // Coach only the sensors that are actually below the bar —
                // each one calibrates with a DIFFERENT motion, so a generic
                // "rotate the board" line can't get a user to green.
                if calibration.accelerometer < Self.usableLevel {
                    tip("A", "Rest the board on each of its faces for a few seconds, like rolling a die.")
                }
                if calibration.gyroscope < Self.usableLevel {
                    tip("G", "Set the board down and keep it still for a moment.")
                }
                if calibration.magnetometer < Self.usableLevel {
                    tip("M", "Trace a slow figure-8 in the air — away from metal, chargers, and other electronics.")
                }
            case .ready:
                Text("Accuracy is good enough to record. Nearby electronics can lower the magnetometer rating — that's normal indoors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .fullyCalibrated:
                EmptyView()
            }
        }
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func chip(_ label: String, level: UInt8) -> some View {
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 22)
            .background(Capsule().fill(color(for: level)))
    }

    private func tip(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for level: UInt8) -> Color {
        switch level {
        case 0:  Palette.danger
        case 1:  Palette.warning
        case 2:  Palette.info
        default: Palette.success
        }
    }

    private func levelName(_ level: UInt8) -> String {
        switch level {
        case 0:  "unreliable"
        case 1:  "low"
        case 2:  "medium"
        default: "high"
        }
    }

    private var accessibilitySummary: String {
        let status = switch readiness {
        case .calibrating:     "calibrating"
        case .ready:           "ready to record"
        case .fullyCalibrated: "fully calibrated"
        }
        return "Fusion calibration \(status): accelerometer \(levelName(calibration.accelerometer)), "
        + "gyroscope \(levelName(calibration.gyroscope)), "
        + "magnetometer \(levelName(calibration.magnetometer))"
    }
}
