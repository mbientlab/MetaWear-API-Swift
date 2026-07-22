import SwiftUI
import MetaWear

/// Compact readout of the fusion algorithm's per-sensor calibration accuracy.
///
/// Bosch's fusion outputs (especially heading) are unreliable until the
/// algorithm has calibrated itself against real motion, and nothing else in
/// the UI ever said so. Three chips — A(ccelerometer), G(yroscope),
/// M(agnetometer) — show the chip's own 0–3 accuracy report; a hint line
/// explains what to do until every sensor reaches HIGH.
struct FusionCalibrationBadge: View {
    let calibration: MWSensorFusionCalibration

    private var isCalibrated: Bool {
        calibration.accelerometer == 3 && calibration.gyroscope == 3 && calibration.magnetometer == 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isCalibrated ? "checkmark.seal.fill" : "scope")
                    .foregroundStyle(isCalibrated ? Palette.success : Palette.warning)
                Text(isCalibrated ? "Calibrated" : "Calibrating…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                chip("A", level: calibration.accelerometer)
                chip("G", level: calibration.gyroscope)
                chip("M", level: calibration.magnetometer)
            }
            if !isCalibrated {
                Text("Rotate the board through a few 45° turns until every sensor reads green.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        "Fusion calibration: accelerometer \(levelName(calibration.accelerometer)), "
        + "gyroscope \(levelName(calibration.gyroscope)), "
        + "magnetometer \(levelName(calibration.magnetometer))"
    }
}
