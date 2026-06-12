import SwiftUI
import MetaWear

/// Form section with a "Sensors" list and an "Add Sensor" menu. Reused by
/// both `SensorConfigView` (live streaming) and `LogSessionView` (on-board
/// logging) so they share the same picker UX, filtering rules, and conflict
/// guards. The owning view passes the set of sensor families it supports —
/// streaming allows all sensors, logging excludes the polled-only sensors
/// (temperature / humidity / ambient light) because those aren't natively
/// loggable on the board's flash.
struct SensorPickerSection: View {
    @Binding var selections: [SensorSelection]
    /// Modules the connected board reported as `isPresent` during discovery.
    /// When non-empty, the Add menu only offers sensors whose module is in
    /// this set. Empty means "discovery hasn't completed yet" — fall back
    /// to showing everything so the first frame isn't blank.
    let availableModules: Set<MWModule>
    /// Temperature module's `extra` bytes decoded into channel sources.
    /// Only used by SensorRow when temperature is selected and the board
    /// has more than one channel.
    let availableTempChannels: [TempChannel]
    /// Which sensor families the calling screen supports. Sensors outside
    /// this set are hidden from the Add menu regardless of the board's
    /// module presence.
    let supportedKinds: Set<SensorKey.Kind>
    /// When true, the entire section is locked — used by `LogSessionView`
    /// while a session is recording so the sensor list (and its rate / range
    /// pickers, Add menu, swipe-to-remove) can't be edited mid-session. The
    /// SwiftUI `.disabled` modifier handles the grey-out automatically.
    var isLocked: Bool = false

    var body: some View {
        Section("Sensors") {
            ForEach($selections) { $sel in
                SensorRow(
                    selection: $sel,
                    tempChannels: availableTempChannels,
                    onRemove: { selections.removeAll { $0.id == sel.id } }
                )
            }
            // Hide the Add menu outright when locked instead of relying
            // on `.disabled` — SwiftUI's `.disabled` on a Section reliably
            // greys out Pickers (since they pick up the trait) but the
            // Menu's custom Label keeps its full-color appearance, which
            // misleads the user into thinking the row is still tappable.
            // Removing it entirely is unambiguous.
            if !isLocked {
                Menu {
                    addSensorMenu
                } label: {
                    Label("Add Sensor", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
            }
        }
        .disabled(isLocked)
    }

    @ViewBuilder
    private var addSensorMenu: some View {
        if supports(.accelerometer), has(.accelerometer) {
            Button("Accelerometer") { add(.accelerometer) }
        }
        if supports(.gyroscope), has(.gyroscope) {
            Button("Gyroscope") { add(.gyroscope) }
        }
        if supports(.magnetometer), has(.magnetometer) {
            Button("Magnetometer") { add(.magnetometer) }
        }
        if supports(.barometer), has(.barometer) {
            Button("Barometer") { add(.barometer) }
        }
        if supports(.temperature), has(.temperature) {
            Button("Temperature") { add(.temperature) }
        }
        if supports(.humidity), has(.humidity) {
            Button("Humidity") { add(.humidity) }
        }
        if supports(.ambientLight), has(.ambientLight) {
            Button("Ambient Light") { add(.ambientLight) }
        }
        // Sensor fusion runs one algorithm on the board so we expose it as
        // a single user-facing selection; the submenu hides once any fusion
        // output is already in the selections list. Conflicts with the
        // raw IMU sensors are resolved in `add()` by auto-clearing the
        // other side rather than hiding entries (so the menu always shows
        // every supported sensor on the board).
        if supports(.sensorFusion), hasModule(.sensorFusion), !fusionSelected {
            Menu("Sensor Fusion") {
                ForEach(SensorFusionOutput.allCases) { out in
                    Button(out.displayName) { add(.sensorFusion(out)) }
                }
            }
        }
    }

    // MARK: - Mutation

    private func add(_ key: SensorKey) {
        guard !selections.contains(where: { $0.id == key }) else { return }
        // Sensor fusion is mutually exclusive with the raw IMU sensors —
        // resolving the conflict here lets us always show every option in
        // the Add menu instead of silently hiding entries.
        switch key {
        case .sensorFusion:
            selections.removeAll { $0.id == .accelerometer || $0.id == .gyroscope || $0.id == .magnetometer }
        case .accelerometer, .gyroscope, .magnetometer:
            selections.removeAll { if case .sensorFusion = $0.id { true } else { false } }
        default:
            break
        }
        let defaultRange: Int?
        switch key {
        case .accelerometer: defaultRange = 2
        case .gyroscope:     defaultRange = 2000
        default:             defaultRange = nil
        }
        selections.append(SensorSelection(id: key, hz: key.defaultHz, range: defaultRange))
    }

    // MARK: - Filtering helpers

    private func supports(_ kind: SensorKey.Kind) -> Bool {
        supportedKinds.contains(kind)
    }

    /// Whether the connected board reports this sensor's module as present.
    /// Treats an empty `availableModules` as "discovery hasn't run yet" so
    /// the menu isn't blank on first open.
    private func has(_ key: SensorKey) -> Bool {
        hasModule(key.module)
    }

    private func hasModule(_ module: MWModule) -> Bool {
        availableModules.isEmpty || availableModules.contains(module)
    }

    /// Whether any sensor-fusion output is already in `selections`. Used to
    /// collapse the fusion submenu once one is picked (we only support a
    /// single fusion output at a time on the board).
    private var fusionSelected: Bool {
        selections.contains { if case .sensorFusion = $0.id { true } else { false } }
    }
}

// MARK: - Row

struct SensorRow: View {
    @Binding var selection: SensorSelection
    let tempChannels: [TempChannel]
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: selection.systemImage)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(selection.displayName)
            Spacer()
            if selection.id == .temperature, tempChannels.count > 1 {
                Picker("Channel", selection: channelBinding) {
                    ForEach(tempChannels) { ch in
                        Text(ch.displayName).tag(ch.index)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            if let rangeOptions = selection.id.rangeOptions, let unit = selection.id.rangeUnit {
                Picker("Range", selection: rangeBinding) {
                    ForEach(rangeOptions, id: \.self) { r in
                        Text("±\(r) \(unit)").tag(r)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            Picker("Rate", selection: $selection.hz) {
                ForEach(selection.id.rateOptions, id: \.self) { rate in
                    Text("\(rate, format: rateFormat) Hz").tag(rate)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .swipeActions {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var rangeBinding: Binding<Int> {
        Binding(
            get: { selection.range ?? selection.id.rangeOptions?.first ?? 0 },
            set: { selection.range = $0 }
        )
    }

    private var channelBinding: Binding<Int> {
        Binding(
            get: { selection.channel ?? 0 },
            set: { selection.channel = $0 }
        )
    }

    private var rateFormat: FloatingPointFormatStyle<Double> {
        let options = selection.id.rateOptions
        let allInteger = options.allSatisfy { $0.rounded() == $0 }
        return allInteger
            ? .number.precision(.fractionLength(0))
            : .number.precision(.fractionLength(0...1))
    }
}
