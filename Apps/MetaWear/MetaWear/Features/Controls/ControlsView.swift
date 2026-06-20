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
                @Bindable var viewModel = viewModel
                Section("LED") {
                    Picker("Color", selection: $viewModel.ledColor) {
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
                    // Driven by the board's discovered modules: each one-shot-
                    // readable sensor appears only when present (temperature is on
                    // every board; pressure / ambient-light depend on the model).
                    ForEach(quickReads.filter { viewModel.availableModules.contains($0.module) }) { spec in
                        QuickReadRow(
                            title: spec.title,
                            icon: spec.icon,
                            value: spec.value(viewModel),
                            isLoading: spec.isLoading(viewModel)
                        ) { Task { await spec.read(viewModel) } }
                    }
                }

                Section("Haptic") {
                    Stepper("Duty cycle: \(viewModel.motorDutyPercent)%",
                            value: $viewModel.motorDutyPercent,
                            in: 0...100, step: 10)
                    Stepper("Pulse width: \(viewModel.motorPulseMilliseconds) ms",
                            value: $viewModel.motorPulseMilliseconds,
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
            await viewModel?.loadModules()
        }
        .alert(item: Binding(
            get: { viewModel?.lastError },
            set: { viewModel?.lastError = $0 }
        )) { err in
            Alert(title: Text("Control failed"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private static func formattedMeasurement(_ value: Float, unit: String) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " " + unit
    }

    /// One-shot-readable sensors offered in Quick Reads, each gated on its module
    /// being present on the connected board. Add a spec to offer another one-shot
    /// read — no other view change needed.
    private var quickReads: [QuickReadSpec] {
        [
            QuickReadSpec(id: "temperature", title: "Temperature", icon: "thermometer.medium", module: .temperature,
                          value: { vm in vm.temperatureC.map { Self.formattedMeasurement($0, unit: "°C") } },
                          isLoading: { $0.isReadingTemperature },
                          read: { vm in await vm.readTemperature() }),
            QuickReadSpec(id: "pressure", title: "Pressure", icon: "barometer", module: .barometer,
                          value: { vm in vm.pressurePa.map { Self.formattedMeasurement($0 / 100, unit: "hPa") } },
                          isLoading: { $0.isReadingPressure },
                          read: { vm in await vm.readPressure() }),
            QuickReadSpec(id: "ambientLight", title: "Ambient Light", icon: "sun.max", module: .ambientLight,
                          value: { vm in vm.ambientLightLux.map { Self.formattedMeasurement($0, unit: "lux") } },
                          isLoading: { $0.isReadingLight },
                          read: { vm in await vm.readAmbientLight() }),
        ]
    }
}

/// Describes one Quick Reads row: which board module gates it, plus how to read
/// the value, format it, and reflect the in-flight state. Keeps the section's
/// presence-gating uniform instead of hardcoding each sensor.
private struct QuickReadSpec: Identifiable {
    let id: String
    let title: String
    let icon: String
    let module: MWModule
    let value: (ControlsViewModel) -> String?
    let isLoading: (ControlsViewModel) -> Bool
    let read: (ControlsViewModel) async -> Void
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
