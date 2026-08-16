import SwiftUI
import MetaWear
import MetaWearFirmware

/// Sheet presented from `ScanView` when the user taps a MetaBoot-mode
/// device row. Auto-latest firmware flash only — no file-picker fallback,
/// no version selection. Failure = show the error, offer a retry, and
/// direct the user to reconnect the board.
struct MetaBootUpdateView: View {

    let advertisement: MetaBootAdvertisement

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MetaBootUpdateViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    content(vm: vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Update Firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .disabled(viewModel?.isBusy == true)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = MetaBootUpdateViewModel(advertisement: advertisement)
                await viewModel?.prepareFlash()
            }
        }
    }

    // MARK: - Body per phase

    @ViewBuilder
    private func content(vm: MetaBootUpdateViewModel) -> some View {
        switch vm.phase {
        case .idle, .loadingDeviceInfo:
            loadingBody
        case .readyToFlash(let build, let info):
            readyBody(vm: vm, build: build, info: info)
        case .flashing(let progress):
            flashingBody(progress: progress)
        case .completed:
            completedBody
        case .failed(let message):
            failedBody(vm: vm, message: message)
        }
    }

    // MARK: - Phase views

    private var loadingBody: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Reading device information…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func readyBody(
        vm: MetaBootUpdateViewModel,
        build: MWFirmwareBuild,
        info: MetaBootDeviceInfo
    ) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            deviceHeader
            VStack(alignment: .leading, spacing: 12) {
                Text("Device")
                    .font(.headline)
                infoRow("Hardware", info.hardwareRevision)
                infoRow("Model", info.modelNumber)
                infoRow("Bootloader", info.bootloaderVersion)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Firmware to flash")
                    .font(.headline)
                infoRow("Version", build.firmwareRev)
                if let bootloader = build.requiredBootloader, !bootloader.isEmpty {
                    infoRow("Requires bootloader ≥", bootloader)
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { await vm.flashLatest() }
            } label: {
                Label("Flash Latest Firmware", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private func flashingBody(progress: DFUProgress) -> some View {
        VStack(spacing: 24) {
            deviceHeader
            VStack(spacing: 12) {
                phaseLabel(for: progress.state)
                    .font(.headline)
                ProgressView(
                    value: progress.state == .uploading ? progress.percentComplete : 0,
                    total: 100
                )
                .progressViewStyle(.linear)
                if progress.state == .uploading {
                    HStack {
                        Text("\(Int(progress.percentComplete))%")
                        Spacer()
                        if progress.totalParts > 1 {
                            Text("Part \(progress.currentPart) of \(progress.totalParts)")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Text("Do not disconnect the board or close the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var completedBody: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(Palette.info)
            Text("Firmware Updated")
                .font(.title2.weight(.semibold))
            Text("The board is rebooting into application mode. Turn off MetaBoot and reconnect from the scan list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }

    private func failedBody(vm: MetaBootUpdateViewModel, message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Palette.warning)
            Text("Update Failed")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                Task { await vm.prepareFlash() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    // MARK: - Bits

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Palette.warning)
                Text(advertisement.name)
                    .font(.title3.weight(.semibold))
            }
            Text(advertisement.identifier.uuidString.prefix(8))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    private func phaseLabel(for state: DFUProgress.State) -> Text {
        switch state {
        case .fetchingCatalog:      return Text("Fetching catalog…")
        case .downloadingFirmware:  return Text("Downloading firmware…")
        case .bootloaderHandoff:    return Text("Switching to bootloader…")
        case .scanning:             return Text("Connecting…")
        case .connecting:           return Text("Connecting…")
        case .starting:             return Text("Starting…")
        case .validating:           return Text("Validating…")
        case .uploading:            return Text("Uploading firmware…")
        case .disconnecting:        return Text("Finishing…")
        case .completed:            return Text("Done")
        case .aborted:              return Text("Aborted")
        }
    }
}
