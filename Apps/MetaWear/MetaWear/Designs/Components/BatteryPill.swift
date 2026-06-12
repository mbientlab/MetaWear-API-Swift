import SwiftUI
import MetaWear

struct BatteryPill: View {
    let battery: BatteryState?

    var body: some View {
        Label {
            Text(label)
                .font(.metricCaption)
                .monospacedDigit()
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .glassPill(tint: tint.opacity(0.18))
        .accessibilityLabel(accessibilityText)
    }

    private var icon: String {
        guard let battery else { return "battery.0" }
        return switch battery.charge {
        case 0..<10:  "battery.0"
        case 10..<25: "battery.25"
        case 25..<50: "battery.50"
        case 50..<75: "battery.75"
        default:      "battery.100"
        }
    }

    private var tint: Color {
        guard let battery else { return .secondary }
        return switch battery.charge {
        case 0..<15:  Palette.danger
        case 15..<35: Palette.warning
        default:      Palette.success
        }
    }

    private var label: String {
        guard let battery else { return "—" }
        return "\(battery.charge)%"
    }

    private var accessibilityText: String {
        guard let battery else { return "Battery unknown" }
        return "Battery \(battery.charge) percent"
    }
}
