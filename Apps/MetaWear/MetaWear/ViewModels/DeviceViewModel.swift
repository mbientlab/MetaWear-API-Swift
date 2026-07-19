import Foundation
import Observation
import MetaWear
import os

/// Presentation model for the connected-device overview.
///
/// Mirrors immutable device facts, live battery state, and module discovery
/// into main-actor state that SwiftUI can render without repeatedly crossing
/// the `MetaWearDevice` actor boundary.
@Observable
@MainActor
final class DeviceViewModel {
    private let device: MetaWearDevice
    let appStore: AppStore

    var deviceInfo: MWDeviceInformation?
    var battery: BatteryState?
    var macAddress: String?
    var lastError: AppError?
    /// Snapshot of the board's module discovery map captured during
    /// `refreshAfterConnect`. Surfaced in Device Info so the user can
    /// inspect which sensors are present, their implementation byte (e.g.
    /// BMI160 vs BMI270 for the accelerometer), and their revision.
    var modules: [MWModule: MWModuleInfo] = [:]

    @ObservationIgnored private let batteryPoller = BatteryPoller()

    init(device: MetaWearDevice, appStore: AppStore) {
        self.device = device
        self.appStore = appStore
    }

    var identifier: UUID { device.identifier }

    func refreshAfterConnect() async {
        // Wait until AppStore reports the connect cycle has settled.
        // Otherwise we'd query the actor mid-connect and get stale data.
        while appStore.connectionState == .connecting {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard appStore.connectionState != .disconnected else { return }
        deviceInfo = await device.deviceInfo
        modules = await device.modules
        await refreshBattery()
        await refreshMAC()
        startBatteryPolling()
    }

    func disconnect() async {
        stopBatteryPolling()
        await appStore.disconnect()
    }

    func reconnect() async {
        do {
            try await device.reconnect()
            await refreshAfterConnect()
        } catch {
            lastError = AppError(error: error)
        }
    }

    func factoryReset() async {
        do {
            try await device.factoryReset()
        } catch {
            lastError = AppError(error: error)
        }
    }

    func rename(to newName: String) async {
        do {
            try await device.send(MWSettings.SetDeviceName(validating: newName))
            // Make the rename VISIBLE immediately. Every displayed name comes
            // from the scanner's advertised-name cache, and a connected board
            // doesn't advertise — without these, nothing on screen changes
            // until a disconnect + rescan + reconnect cycle.
            appStore.scanner.noteAdvertisedName(newName, for: device.identifier)
            appStore.renameRememberedDevice(
                peripheralUUID: device.identifier, mac: macAddress, to: newName
            )
            await refreshMACBroadcastAfterRename(newName)
        } catch {
            lastError = AppError(error: error)
        }
    }

    /// The MAC-broadcast scan response freezes its embedded name at
    /// configuration time — keep it in sync after a rename on any board
    /// that broadcasts its MAC. Gated on the host-local configured set OR
    /// the observed advertisement: a board configured by the user's OTHER
    /// device must be refreshed here too, or its scan response would keep
    /// broadcasting the old name forever. Best-effort: a failure leaves the
    /// old name on air until the next reconfiguration; it never blocks the
    /// rename itself.
    private func refreshMACBroadcastAfterRename(_ newName: String) async {
        guard let mac = macAddress else { return }
        let broadcastsMAC = appStore.macAdvertisementConfigured.contains(mac)
            || appStore.scanner.advertisedMACs[device.identifier] != nil
        guard broadcastsMAC else { return }
        do {
            try await device.updateMACAdvertisement(advertisedName: newName)
            AppStore.log.info("Refreshed MAC broadcast name for \(mac, privacy: .public)")
        } catch {
            AppStore.log.error("MAC broadcast rename refresh failed for \(mac, privacy: .public): \(error, privacy: .public)")
        }
    }

    func identify() async {
        do {
            try await device.send(MWLED.SetPattern(color: .green, .flash))
            try await device.send(MWLED.Play())
        } catch {
            lastError = AppError(error: error)
        }
    }

    func refreshBattery() async {
        do {
            battery = try await device.readBattery()
        } catch {
            lastError = AppError(error: error)
        }
    }

    private func refreshMAC() async {
        do {
            let result = try await device.read(MWSettings.ReadMacAddress())
            macAddress = result.value
        } catch {
            macAddress = nil
        }
    }

    private func startBatteryPolling() {
        stopBatteryPolling()
        batteryPoller.task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await refreshBattery()
            }
        }
    }

    private func stopBatteryPolling() {
        batteryPoller.cancel()
    }

    private final class BatteryPoller {
        var task: Task<Void, Never>? {
            didSet { oldValue?.cancel() }
        }

        deinit {
            task?.cancel()
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}
