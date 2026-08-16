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

    // MARK: - MetaBoot mode
    //
    // The scanner has a single active scan mode: `.metaWear` (default) or
    // `.metaBoot`. In MetaBoot mode the discoveredDevices list stops
    // updating and `metaBootDevices` populates instead. The mode-switch
    // semantics (one or the other, never both) come from the SDK — this
    // view model just exposes the toggle to the toolbar.

    /// True when the scanner is surfacing bootloader-mode boards instead of
    /// application-mode boards.
    var isMetaBootMode: Bool { scanner.scanMode == .metaBoot }

    /// Bootloader-mode boards currently on air, sorted by identifier for a
    /// stable UI order. There's no advertised-name cache for MetaBoot to
    /// sort against — the local name is almost always the literal string
    /// "MetaBoot".
    var metaBootDevices: [MetaBootAdvertisement] {
        Array(scanner.discoveredMetaBootDevices.values)
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
    }

    /// Flip between application-mode and bootloader-mode scanning. Clears
    /// the "other mode"'s discovered-devices list — mode is either/or, so
    /// leaving stale entries would confuse the "one mode's devices at a
    /// time" invariant.
    func toggleMetaBootMode() {
        scanner.setScanMode(scanner.scanMode == .metaBoot ? .metaWear : .metaBoot)
    }

    /// Wipe the MetaBoot list and let the scan rebuild it from live
    /// advertisements. Called when the firmware-update sheet closes: a
    /// just-flashed board is back in application mode, but its UUID keeps
    /// advertising (as a MetaWear now), so freshness alone would never cull
    /// the stale bootloader entry. Boards genuinely still in MetaBoot
    /// re-appear within about a second.
    func refreshMetaBootScan() {
        scanner.clearMetaBootDevices()
        scanner.startScan()   // no-op if the scan is already running
    }

    // Connected-state RSSI polling lives in AppStore (`connectedRSSI`): the
    // connection lifecycle is owned there, and a connected board stops
    // advertising, so scan-side RSSI has nothing to say about it.
}
