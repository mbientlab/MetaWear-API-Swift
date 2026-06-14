import Foundation
import Observation
import MetaWear

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

    private var batteryPollTask: Task<Void, Never>?

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
        } catch {
            lastError = AppError(error: error)
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
        batteryPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refreshBattery()
            }
        }
    }

    private func stopBatteryPolling() {
        batteryPollTask?.cancel()
        batteryPollTask = nil
    }
}
