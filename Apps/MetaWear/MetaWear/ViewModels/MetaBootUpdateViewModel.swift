import Foundation
import Observation
import MetaWear
import MetaWearFirmware
import os

/// Presentation model for the "Flash a MetaBoot-mode device" sheet reached
/// from `ScanView` while the scanner is in MetaBoot mode.
///
/// Wraps `MetaBootFirmwareUpdater.updateFirmwareToLatest(identifier:)`:
/// reads the board's hardware/model from its MetaBoot Device Information
/// Service, looks up the latest firmware on the MbientLab catalog, and
/// flashes it. The "latest only" scope is deliberate — the app doesn't
/// offer a file picker for MetaBoot rescue flows.
@Observable
@MainActor
final class MetaBootUpdateViewModel {

    /// One coarse UI state for the sheet. Associated values carry exactly
    /// what each state needs to render.
    enum Phase: Equatable {
        /// Just opened; ready to start the flow.
        case idle
        /// Reading the DIS to identify the board (hardware/model needed to
        /// pick the right catalog row).
        case loadingDeviceInfo
        /// Board identified, we know what firmware we'd flash. Show a
        /// confirm-style panel with the version.
        case readyToFlash(MWFirmwareBuild, deviceInfo: MetaBootDeviceInfo)
        /// Flash in progress; the value is the latest `DFUProgress` event.
        case flashing(DFUProgress)
        /// Flash finished successfully. Board should reboot into
        /// application mode on its own within a few seconds.
        case completed
        /// Anything failed; the value is a user-facing message.
        case failed(String)
    }

    let advertisement: MetaBootAdvertisement

    private(set) var phase: Phase = .idle

    /// True while a network / DIS read / flash is in flight. Drives the
    /// action button's disabled state.
    var isBusy: Bool {
        switch phase {
        case .loadingDeviceInfo, .flashing: return true
        default: return false
        }
    }

    init(advertisement: MetaBootAdvertisement) {
        self.advertisement = advertisement
    }

    // MARK: - Actions

    /// Step 1 for the sheet: identify the board and look up the target
    /// build. Split from `flashLatest` so a network hiccup during catalog
    /// lookup lets the user retry without a fresh CoreBluetooth probe.
    ///
    /// Any catalog / probe failure lands in `.failed`; no file-picker
    /// fallback (per spec — MetaBoot mode in the app is auto-latest only).
    func prepareFlash(server: MWFirmwareServer = MWFirmwareServer()) async {
        phase = .loadingDeviceInfo
        do {
            let info = try await MetaBootDeviceInfo.read(identifier: advertisement.identifier)
            let build = try await server.latestBuild(
                hardwareRev: info.hardwareRevision,
                modelNumber: info.modelNumber
            )
            phase = .readyToFlash(build, deviceInfo: info)
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// Step 2: kick off the flash. Streams `DFUProgress` into `phase`;
    /// terminal state is either `.completed` or `.failed`.
    func flashLatest() async {
        var sawCompleted = false
        do {
            for try await progress in MetaBootFirmwareUpdater.updateFirmwareToLatest(
                identifier: advertisement.identifier
            ) {
                phase = .flashing(progress)
                if progress.state == .completed { sawCompleted = true }
            }
        } catch {
            phase = .failed(message(for: error))
            return
        }
        // Nordic's stream can finish without a `.completed` event if the
        // flash aborted cleanly (e.g. user cancelled iteration). Only
        // claim success when we actually saw the completion state.
        phase = sawCompleted ? .completed : .failed("Flash ended without completing.")
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
