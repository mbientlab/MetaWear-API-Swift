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
}
