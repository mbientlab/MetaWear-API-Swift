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
    func stopScan() { scanner.stopScan() }

    func advertisedName(for id: UUID) -> String? {
        scanner.advertisedNames[id]
    }

    // Connected-state RSSI polling lives in AppStore (`connectedRSSI`): the
    // connection lifecycle is owned there, and a connected board stops
    // advertising, so scan-side RSSI has nothing to say about it.
}
