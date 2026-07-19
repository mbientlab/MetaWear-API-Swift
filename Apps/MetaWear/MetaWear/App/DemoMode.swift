import Foundation
import MetaWear

/// Demo mode injects a fully simulated MetaWear (see `DemoBLETransport`) into
/// the scan list — no hardware, no Bluetooth. Every screen becomes reachable:
/// live streaming shows synthetic waveforms, logging records and downloads a
/// synthetic session, device info/battery/RSSI all answer.
///
/// Enabled automatically on the simulator (where CoreBluetooth doesn't exist)
/// and on device via the `-MWDemo` launch argument — useful for App Store
/// screenshots and design review.
enum DemoMode {
    static let isEnabled: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-MWDemo")
        #endif
    }()

    static let deviceName = "Simulated MetaWear"

    /// The simulated fleet: three boards so multi-board flows (group
    /// logging, per-board attribution) are testable in the simulator.
    /// Board 0 is the legacy single demo device, byte-for-byte.
    static let identities: [DemoBLETransport.Identity] = (0..<3).map { .board($0) }

    /// True when `id` belongs to ANY demo board — use this, never equality
    /// with `DemoBLETransport.deviceIdentifier`, which is only board 0.
    static func isDemoID(_ id: UUID) -> Bool {
        identities.contains { $0.identifier == id }
    }

    /// Display name for a demo board ("Simulated MetaWear", "Simulated
    /// MetaWear 2", …); nil for non-demo IDs.
    static func name(for id: UUID) -> String? {
        guard let index = identities.firstIndex(where: { $0.identifier == id }) else {
            return nil
        }
        return index == 0 ? deviceName : "\(deviceName) \(index + 1)"
    }
}
