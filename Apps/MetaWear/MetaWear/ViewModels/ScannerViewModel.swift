import Foundation
import Observation
import MetaWear

/// Presentation model for scan results.
///
/// Wraps `MetaWearScanner` with sorted device lists and optional RSSI polling
/// for connected devices while keeping CoreBluetooth state owned by the SDK.
@Observable
@MainActor
final class ScannerViewModel {
    private let scanner: MetaWearScanner
    var rssi: [UUID: Int] = [:]
    private var rssiTasks: [UUID: Task<Void, Never>] = [:]

    init(scanner: MetaWearScanner) {
        self.scanner = scanner
    }

    var devices: [MetaWearDevice] {
        Array(scanner.discoveredDevices.values)
            .sorted { scanner.advertisedNames[$0.identifier] ?? "" < scanner.advertisedNames[$1.identifier] ?? "" }
    }

    var isScanning: Bool { scanner.isScanning }

    func toggleScan() {
        scanner.isScanning ? scanner.stopScan() : scanner.startScan()
    }

    func startScan() { scanner.startScan() }
    func stopScan() {
        scanner.stopScan()
        rssiTasks.values.forEach { $0.cancel() }
        rssiTasks.removeAll()
    }

    func advertisedName(for id: UUID) -> String? {
        scanner.advertisedNames[id]
    }

    func beginRSSIPolling(for device: MetaWearDevice) {
        let id = device.identifier
        rssiTasks[id]?.cancel()
        rssiTasks[id] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let value = try await device.readRSSI()
                    guard !Task.isCancelled else { return }
                    self?.rssi[id] = value
                } catch {
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopRSSIPolling(for id: UUID) {
        rssiTasks[id]?.cancel()
        rssiTasks.removeValue(forKey: id)
    }
}
