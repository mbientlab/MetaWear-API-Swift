@preconcurrency import CoreBluetooth
import Foundation

/// Owns the single CBCentralManager for the process.
/// Routes scan results and central-level callbacks (connect/disconnect) to the
/// correct per-device CoreBluetoothPeripheralTransport by peripheral UUID.
actor MWCentralManager: NSObject {

    // MARK: - State

    private var central: CBCentralManager!
    /// Peripherals seen during scan — populated before a transport exists.
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    /// Transports that are actively connecting or connected, keyed by peripheral UUID.
    private var transports: [UUID: CoreBluetoothPeripheralTransport] = [:]

    // MARK: - Scan

    private var scanContinuation: AsyncStream<ScanResult>.Continuation?
    private var pendingScanServices: [CBUUID]?

    // MARK: - Init

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API used by MetaWearScanner

    /// Start scanning and yield results until the caller cancels the stream.
    func scan(for services: [CBUUID]?) -> AsyncStream<ScanResult> {
        let serviceStrings = services?.map { $0.uuidString }
        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            Task {
                await self.beginScan(serviceStrings: serviceStrings, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.endScan() }
            }
        }
    }

    // MARK: - API used by CoreBluetoothPeripheralTransport

    /// Look up the peripheral by identifier, register the transport, and ask
    /// CoreBluetooth to connect. Throws if the peripheral is unknown.
    ///
    /// CBPeripheral stays inside this actor — it is never returned across the
    /// actor boundary, eliminating the Swift 6 non-Sendable transfer error.
    func requestConnect(identifier: UUID, transport: CoreBluetoothPeripheralTransport) throws {
        guard let peripheral = knownPeripherals[identifier]
                ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            mwLog("[BLE] requestConnect: peripheral \(identifier) not found")
            throw MWError.operationFailed("Peripheral \(identifier) not found")
        }
        mwLog("[BLE] requestConnect: \(identifier)")
        knownPeripherals[peripheral.identifier] = peripheral
        transports[peripheral.identifier] = transport
        central.connect(peripheral, options: nil)
    }

    /// Ask CoreBluetooth to disconnect by identifier.
    func requestDisconnect(identifier: UUID) {
        mwLog("[BLE] requestDisconnect: \(identifier)")
        guard let peripheral = knownPeripherals[identifier] else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Private scan helpers

    private func beginScan(serviceStrings: [String]?, continuation: AsyncStream<ScanResult>.Continuation) {
        let services = serviceStrings?.map { CBUUID(string: $0) }
        scanContinuation = continuation
        pendingScanServices = services
        guard central.state == .poweredOn else {
            mwLog("[BLE] beginScan: central not powered on (state=\(central.state.rawValue)), deferring")
            return
        }
        mwLog("[BLE] beginScan: starting scan")
        central.scanForPeripherals(withServices: services, options: nil)
    }

    private func endScan() {
        mwLog("[BLE] endScan")
        scanContinuation = nil
        pendingScanServices = nil
        guard central.state == .poweredOn else { return }
        central.stopScan()
    }
}

// MARK: - CBCentralManagerDelegate

extension MWCentralManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { await self.handleStateUpdate(central.state) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString }.joined(separator: ",") ?? "none"
        mwLog("[BLE] didDiscover: \(peripheral.identifier) name=\(name ?? "nil") rssi=\(RSSI) services=[\(serviceUUIDs)]")
        let result = ScanResult(identifier: peripheral.identifier, name: name, rssi: RSSI.intValue)
        Task {
            await self.cachePeripheral(peripheral)
            await self.scanContinuation?.yield(result)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { await self.handleConnect(peripheral: peripheral) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { await self.handleFailToConnect(peripheral: peripheral, error: error) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { await self.handleDisconnect(peripheral: peripheral, error: error) }
    }

    // MARK: - Handlers

    private func handleStateUpdate(_ state: CBManagerState) {
        mwLog("[BLE] centralManagerDidUpdateState: \(state.rawValue)")
        if state == .poweredOn, scanContinuation != nil {
            // A scan was requested before BT was ready — start it now.
            mwLog("[BLE] handleStateUpdate: BT now poweredOn, starting deferred scan")
            central.scanForPeripherals(withServices: pendingScanServices, options: nil)
        }
    }

    private func cachePeripheral(_ peripheral: CBPeripheral) {
        knownPeripherals[peripheral.identifier] = peripheral
    }

    private func handleConnect(peripheral: CBPeripheral) {
        mwLog("[BLE] didConnect: \(peripheral.identifier)")
        guard let transport = transports[peripheral.identifier] else { return }
        // Call the nonisolated entry point on the transport directly — no Task, no actor hop,
        // so CBPeripheral is never transferred across actor isolation boundaries.
        transport.handleConnected(peripheral: peripheral)
    }

    private func handleFailToConnect(peripheral: CBPeripheral, error: Error?) {
        mwLog("[BLE] didFailToConnect: \(peripheral.identifier) error=\(error?.localizedDescription ?? "nil")")
        guard let transport = transports.removeValue(forKey: peripheral.identifier) else { return }
        let err = error ?? MWError.operationFailed("Failed to connect to \(peripheral.identifier)")
        Task { await transport.handleFailedToConnect(error: err) }
    }

    private func handleDisconnect(peripheral: CBPeripheral, error: Error?) {
        mwLog("[BLE] didDisconnect: \(peripheral.identifier) error=\(error?.localizedDescription ?? "nil")")
        guard let transport = transports.removeValue(forKey: peripheral.identifier) else { return }
        Task { await transport.handleDisconnected(error: error) }
    }
}
