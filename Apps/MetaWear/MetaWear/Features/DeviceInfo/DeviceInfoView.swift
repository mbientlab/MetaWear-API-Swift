import SwiftUI
import MetaWear

struct DeviceInfoView: View {
    @Environment(AppStore.self) private var appStore
    @State private var viewModel: DeviceViewModel?

    var body: some View {
        Form {
            if let viewModel {
                Section("Identity") {
                    LabeledContent("Model", value: viewModel.deviceInfo?.modelNumber ?? "—")
                    LabeledContent("Manufacturer", value: viewModel.deviceInfo?.manufacturer ?? "—")
                    LabeledContent("Serial", value: viewModel.deviceInfo?.serialNumber ?? "—")
                    LabeledContent("Firmware", value: viewModel.deviceInfo?.firmwareRevision ?? "—")
                    LabeledContent("Hardware", value: viewModel.deviceInfo?.hardwareRevision ?? "—")
                    if let mac = viewModel.macAddress {
                        LabeledContent("MAC", value: mac).font(.body.monospaced())
                    }
                    LabeledContent("Battery") {
                        BatteryPill(battery: viewModel.battery)
                    }
                }

                // List every module the SDK knows about. Present modules
                // show their implementation + revision bytes (e.g.
                // BMI160 vs BMI270 for the accelerometer comes from the
                // implementation byte); absent modules are kept in the
                // list and rendered "—" so the user can tell at a glance
                // what's on this particular board.
                Section("Modules") {
                    ForEach(MWModule.allCases, id: \.self) { module in
                        ModuleRow(name: module.name.capitalized,
                                  info: viewModel.modules[module])
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Device Info")
        .task {
            guard let device = appStore.activeDevice else { return }
            if viewModel == nil {
                viewModel = DeviceViewModel(device: device, appStore: appStore)
                await viewModel?.refreshAfterConnect()
            }
        }
    }
}

/// One row in the Modules section. Shows the module name on the left and
/// either "impl 0xNN · rev N" for present modules or a muted "—" for
/// absent ones. Hex display matches the wire format the firmware reports.
private struct ModuleRow: View {
    let name: String
    let info: MWModuleInfo?

    var body: some View {
        LabeledContent(name) {
            if let info, info.isPresent {
                Text("impl \(hex(info.implementation)) · rev \(info.revision)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private func hex(_ b: UInt8) -> String {
        let raw = String(b, radix: 16, uppercase: true)
        return "0x" + (raw.count == 1 ? "0" + raw : raw)
    }
}
