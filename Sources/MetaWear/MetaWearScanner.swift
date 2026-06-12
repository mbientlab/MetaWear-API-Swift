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

    /// Most-recently-seen advertised local name for each peripheral UUID the
    /// scanner has observed. Unlike `discoveredDevices`, this is updated on
    /// every advertisement (including devices whose name no longer starts
    /// with "MetaWear" — e.g. after a `MWSettings.SetDeviceName` rename) and
    /// can therefore be used to verify a rename propagated to the advertising
    /// layer. Values refresh each scan; call `clearAdvertisedName(for:)` to
    /// force the next scan to re-capture a fresh value for a given UUID.
    public private(set) var advertisedNames: [UUID: String] = [:]

    /// Most-recently-seen manufacturer-specific advertisement bytes for each
    /// peripheral UUID the scanner has observed. This is the raw payload from
    /// `CBAdvertisementDataManufacturerDataKey` — for a MetaWear running in
    /// iBeacon mode it begins with the Apple company ID (`0x4C 0x00`) followed
    /// by the iBeacon sub-type byte (`0x02`), length (`0x15`), UUID, major,
    /// minor, and measured-RSSI reference. Use `clearManufacturerData(for:)`
    /// before a scan to prove a fresh advertisement arrived.
    public private(set) var advertisementManufacturerData: [UUID: Data] = [:]

    /// Most-recently-seen RSSI (in dBm) for each peripheral UUID observed in
    /// advertisements during a scan. Refreshed on every advertisement so UI
    /// can show live signal strength without polling the connected device.
    public private(set) var advertisementRSSI: [UUID: Int] = [:]

    /// Wall-clock timestamp of the most recent advertisement seen for each
    /// peripheral UUID. Lets the UI judge whether a remembered device is
    /// currently in range (recent timestamp) versus simply remembered from
    /// a prior session (stale or missing).
    public private(set) var advertisementLastSeen: [UUID: Date] = [:]

    // MARK: - Private

    private let centralManager: MWCentralManager
    private var scanTask: Task<Void, Never>?
    /// Devices vended via `device(forKnownIdentifier:)` for peripherals the
    /// scanner has not yet seen in the current session (e.g. a remembered
    /// device the user wants to reconnect to before it has re-advertised).
    /// Kept separate from `discoveredDevices` so the latter remains a faithful
    /// "currently visible on air" set.
    private var knownDevices: [UUID: MetaWearDevice] = [:]

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
                // Record every advertisement's name so renamed devices remain
                // observable even when they no longer match the MetaWear prefix.
                self.advertisedNames[id] = name
                self.advertisementRSSI[id] = result.rssi
                self.advertisementLastSeen[id] = .now
                // Record manufacturer data when present — lets tests verify a
                // board has flipped into iBeacon mode by inspecting the Apple
                // company-ID payload broadcast on air.
                if let mfg = result.manufacturerData {
                    self.advertisementManufacturerData[id] = mfg
                }
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

    /// Forget the cached advertised name for a UUID so the next scan must
    /// observe a fresh advertisement before `advertisedNames[uuid]` is
    /// repopulated. Used by verification code that needs to prove a rename
    /// reached the air, not just that CoreBluetooth cached an old value.
    public func clearAdvertisedName(for uuid: UUID) {
        advertisedNames.removeValue(forKey: uuid)
    }

    /// Forget the cached manufacturer-data payload for a UUID so the next
    /// scan must observe a fresh advertisement. Pair with a rescan to verify
    /// the board has transitioned in/out of iBeacon mode.
    public func clearManufacturerData(for uuid: UUID) {
        advertisementManufacturerData.removeValue(forKey: uuid)
    }

    /// Returns a `MetaWearDevice` for a peripheral the app knows by UUID
    /// (typically a remembered device from a previous session) without
    /// requiring the scanner to have re-discovered it on air. iOS can still
    /// connect to such peripherals via `retrievePeripherals(withIdentifiers:)`
    /// inside `MWCentralManager.requestConnect`. Repeated calls return the
    /// same instance, and if the scanner subsequently discovers the same
    /// UUID on air the live `discoveredDevices` entry takes precedence.
    public func device(forKnownIdentifier identifier: UUID) -> MetaWearDevice {
        if let existing = discoveredDevices[identifier] { return existing }
        if let cached = knownDevices[identifier] { return cached }
        let transport = CoreBluetoothPeripheralTransport(
            identifier: identifier,
            centralManager: centralManager
        )
        let device = MetaWearDevice(identifier: identifier, transport: transport)
        knownDevices[identifier] = device
        return device
    }

    public func stopScan() {
        mwLog("[Scanner] stopScan")
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}
