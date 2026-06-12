import SwiftUI
import MetaWear

struct ControlsView: View {
    @Environment(AppStore.self) private var appStore
    @State private var viewModel: ControlsViewModel?
    @State private var presetName: String = "Blink"

    private let presets: [(name: String, pattern: MWLEDPattern)] = [
        ("Solid", .solid),
        ("Blink", .blink),
        ("Breathe", .breathe),
        ("Flash", .flash)
    ]

    var body: some View {
        Form {
            if let viewModel {
                Section("LED") {
                    Picker("Color", selection: Binding(get: { viewModel.ledColor }, set: { viewModel.ledColor = $0 })) {
                        Text("Green").tag(MWLED.Color.green)
                        Text("Red").tag(MWLED.Color.red)
                        Text("Blue").tag(MWLED.Color.blue)
                    }
                    Picker("Pattern", selection: $presetName) {
                        ForEach(presets, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .onChange(of: presetName) { _, new in
                        if let p = presets.first(where: { $0.name == new })?.pattern {
                            viewModel.ledPattern = p
                        }
                    }
                    HStack {
                        Button { Task { await viewModel.playLED() } } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.glassProminent)
                        Button { Task { await viewModel.stopLED() } } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.glass)
                    }
                    // Form-context Buttons default to title-only for the
                    // `Button(title, systemImage:)` initializer, which is
                    // why the icons weren't rendering. Explicit Label
                    // bodies + this style override puts them back.
                    .labelStyle(.titleAndIcon)
                }

                Section("Quick Reads") {
                    QuickReadRow(
                        title: "Temperature",
                        icon: "thermometer.medium",
                        value: viewModel.temperatureC.map { String(format: "%.1f °C", $0) },
                        isLoading: viewModel.isReadingTemperature
                    ) { Task { await viewModel.readTemperature() } }

                    QuickReadRow(
                        title: "Pressure",
                        icon: "barometer",
                        value: viewModel.pressurePa.map { String(format: "%.1f hPa", $0 / 100) },
                        isLoading: viewModel.isReadingPressure
                    ) { Task { await viewModel.readPressure() } }

                    QuickReadRow(
                        title: "Ambient Light",
                        icon: "sun.max",
                        value: viewModel.ambientLightLux.map { String(format: "%.1f lux", $0) },
                        isLoading: viewModel.isReadingLight
                    ) { Task { await viewModel.readAmbientLight() } }
                }

                Section("Haptic") {
                    Stepper("Duty cycle: \(viewModel.motorDuty)%",
                            value: Binding(get: { Int(viewModel.motorDuty) },
                                           set: { viewModel.motorDuty = UInt8(clamping: $0) }),
                            in: 0...100, step: 10)
                    Stepper("Pulse width: \(viewModel.motorPulseMs) ms",
                            value: Binding(get: { Int(viewModel.motorPulseMs) },
                                           set: { viewModel.motorPulseMs = UInt16(clamping: $0) }),
                            in: 50...2000, step: 50)
                    HStack {
                        Button { Task { await viewModel.pulseMotor() } } label: {
                            Label("Motor", systemImage: "iphone.radiowaves.left.and.right")
                        }
                        .buttonStyle(.glassProminent)
                        Button { Task { await viewModel.pulseBuzzer() } } label: {
                            Label("Buzzer", systemImage: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.glass)
                    }
                    .labelStyle(.titleAndIcon)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Controls")
        .task {
            guard let device = appStore.activeDevice else { return }
            if viewModel == nil {
                viewModel = ControlsViewModel(device: device)
            }
        }
    }
}

/// One row in the Quick Reads section. Shows the sensor name + icon, the
/// last-read value (or "—" until the user reads), and a "Read" button on
/// the right that flips to a small spinner while the BLE round-trip is in
/// flight.
private struct QuickReadRow: View {
    let title: String
    let icon: String
    let value: String?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(Palette.accent)
            }
            Spacer()
            Text(value ?? "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Read", action: action)
                    .buttonStyle(.glass)
            }
        }
    }
}
