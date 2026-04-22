import CoreBluetooth
import Foundation

/// Scans for MetaWear peripherals and vends `MetaWearDevice` instances.
///
/// `@MainActor` isolation ensures all mutations to `discoveredDevices` and `isScanning`
/// happen on the main thread — safe to bind directly to SwiftUI views via `@Observable`.
/// One scanner per app; each discovered peripheral gets its own isolated transport.
@Observable
@MainActor
public final class MetaWearScanner {

    // MARK: - Public state

    public private(set) var discoveredDevices: [UUID: MetaWearDevice] = [:]
    public private(set) var isScanning = false

    // MARK: - Private

    private let centralManager: MWCentralManager
    private var scanTask: Task<Void, Never>?

    // MARK: - Init

    public init() {
        self.centralManager = MWCentralManager()
    }

    // MARK: - Scanning

    public func startScan() {
        guard !isScanning else { return }
        mwLog("[Scanner] startScan")
        isScanning = true
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Scan without a service-UUID filter: MetaWear devices don't always
            // include their 128-bit service UUID in advertisement packets.
            let stream = await self.centralManager.scan(for: nil)
            for await result in stream {
                let id = result.identifier
                let name = result.name ?? ""
                mwLog("[Scanner] discovered: \(id) name='\(name)'")
                // Accept only MetaWear peripherals (name starts with "MetaWear").
                guard name.hasPrefix("MetaWear") else { continue }
                guard self.discoveredDevices[id] == nil else { continue }
                mwLog("[Scanner] new MetaWear device: \(id)")
                let transport = CoreBluetoothPeripheralTransport(
                    identifier: id,
                    centralManager: self.centralManager
                )
                self.discoveredDevices[id] = MetaWearDevice(identifier: id, transport: transport)
            }
        }
    }

    public func stopScan() {
        mwLog("[Scanner] stopScan")
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}
