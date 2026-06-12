import SwiftUI
import MetaWear

struct SensorConfigView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.dismiss) private var dismiss
    @State private var selections: [SensorSelection] = [
        SensorSelection(id: .accelerometer, hz: SensorKey.accelerometer.defaultHz, range: 2)
    ]
    @State private var goToStream = false
    @State private var availableModules: Set<MWModule> = []
    @State private var availableTempChannels: [TempChannel] = []

    var body: some View {
        Form {
            SensorPickerSection(
                selections: $selections,
                availableModules: availableModules,
                availableTempChannels: availableTempChannels,
                supportedKinds: Set(SensorKey.Kind.allCases)
            )
            Section {
                BandwidthBadge(
                    aggregateHz: BandwidthAdvisor.aggregateHz(selections),
                    onHalve: { selections = BandwidthAdvisor.halved(selections) }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Configure Stream")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Start", systemImage: "play.fill") {
                    goToStream = true
                }
                .disabled(selections.isEmpty)
                .buttonStyle(.glassProminent)
                .tint(Palette.success)
            }
        }
        .navigationDestination(isPresented: $goToStream) {
            LiveStreamView(selections: selections)
        }
        .task {
            guard let device = appStore.activeDevice else { return }
            let mods = await device.modules
            availableModules = Set(mods.compactMap { $0.value.isPresent ? $0.key : nil })
            if let tempInfo = mods[.temperature], tempInfo.isPresent {
                availableTempChannels = tempInfo.extra.enumerated().compactMap {
                    TempChannel(index: $0.offset, rawSource: $0.element)
                }
            }
        }
    }
}
