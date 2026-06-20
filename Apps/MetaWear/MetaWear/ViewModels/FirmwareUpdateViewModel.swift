import Foundation
import Observation
import MetaWear
import MetaWearFirmware

/// Presentation model for the Settings → Firmware section.
///
/// Wraps the `MetaWearFirmware` DFU API: it checks MbientLab's release catalog
/// for a build newer than the one on the board, and drives an over-the-air
/// update while surfacing `DFUProgress` to the UI. A successful flash reboots
/// the board, which leaves the actor's cached `deviceInfo`/`modules` stale — so
/// this model reconnects through `AppStore` afterwards to refresh them.
@Observable
@MainActor
final class FirmwareUpdateViewModel {

    /// One coarse UI state for the section. Associated values carry exactly
    /// what each state needs to render — the available build to offer, or the
    /// live transfer progress to chart.
    enum Phase: Equatable {
        /// Haven't asked the catalog yet.
        case unknown
        /// Catalog lookup in flight.
        case checking
        /// Catalog says the board is already on the latest build.
        case upToDate
        /// A newer build is available.
        case updateAvailable(MWFirmwareBuild)
        /// Flash in progress; the value is the latest `DFUProgress` event.
        case updating(DFUProgress)
        /// Flash finished and we've reconnected to the (now-updated) board.
        case completed
        /// Something failed; the value is a user-facing message.
        case failed(String)
    }

    private let device: MetaWearDevice
    private let appStore: AppStore

    /// Firmware revision currently on the board (from the Device Information
    /// service), e.g. `"1.7.3"`. Refreshed after a successful update.
    private(set) var currentVersion: String?
    private(set) var phase: Phase = .unknown

    init(device: MetaWearDevice, appStore: AppStore) {
        self.device = device
        self.appStore = appStore
    }

    /// True while a check or flash is in flight — used to gate other controls.
    var isBusy: Bool {
        switch phase {
        case .checking, .updating: return true
        default: return false
        }
    }

    /// Mirror the board's current firmware revision into `currentVersion`.
    /// Cheap (reads the cached `deviceInfo`); safe to call on appear.
    func loadCurrentVersion() async {
        currentVersion = await device.deviceInfo?.firmwareRevision
    }

    /// Ask MbientLab's catalog whether a newer build exists for this board.
    func checkForUpdate() async {
        phase = .checking
        do {
            if let build = try await device.checkForFirmwareUpdate() {
                phase = .updateAvailable(build)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// Flash the latest catalog build, streaming progress into `phase`, then
    /// reconnect to pick up the new firmware.
    ///
    /// Requires the board to be idle (no active stream/log/download). We check
    /// that up front so the user gets a clear message instead of a failure
    /// mid-handoff — by which point the board has already been told to jump to
    /// the bootloader.
    func startUpdate() async {
        guard case .idle = await device.state else {
            phase = .failed(MWFirmwareError.deviceNotIdle.errorDescription
                            ?? "The board must be idle to update firmware.")
            return
        }

        var sawCompleted = false
        do {
            for try await progress in device.updateFirmwareToLatest() {
                phase = .updating(progress)
                if progress.state == .completed { sawCompleted = true }
            }
        } catch {
            // A failure before the bootloader handoff (catalog/download) leaves
            // the board connected and fine; one after it leaves the board in
            // bootloader mode. We don't auto-reconnect here — a normal connect
            // against a bootloader-mode peripheral can stall — so we just
            // report and let the user reconnect from the scan screen.
            phase = .failed(message(for: error))
            return
        }

        guard sawCompleted else {
            // Stream finished without a completion event — nothing was flashed
            // (the catalog had nothing newer). Reflect that honestly rather
            // than claiming success.
            phase = .upToDate
            return
        }

        await reconnect()
        await loadCurrentVersion()
        phase = .completed
    }

    /// Re-establish a coherent connection after the board reboots out of DFU.
    ///
    /// The flash path disconnects the board internally, so `AppStore`'s
    /// `connectionState` is stale (still "connected"). Reset it to
    /// `.disconnected` first so `connect(to:)` runs a full re-handshake — which
    /// repopulates `deviceInfo`/`modules` — instead of early-returning.
    private func reconnect() async {
        appStore.connectionState = .disconnected
        await appStore.connect(to: device)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
