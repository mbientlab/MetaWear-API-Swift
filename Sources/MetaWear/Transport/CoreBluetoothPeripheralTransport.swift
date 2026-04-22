@preconcurrency import CoreBluetooth
import Foundation

/// Per-device BLE transport backed by CoreBluetooth.
///
/// `CBPeripheral` and `CBCharacteristic` objects are stored as
/// `nonisolated(unsafe)` because they must be accessible from both the actor's
/// isolated executor and the `nonisolated` CBPeripheralDelegate callbacks.
/// Safety is ensured structurally:
///  - `peripheral` is set exactly once by `handleConnected` before any
///    actor-isolated code reads it.
///  - `characteristics` is populated during service discovery, which completes
///    before `connectContinuation` resumes (i.e. before any read/write begins).
///  - All subsequent access is serialised by the actor executor.
actor CoreBluetoothPeripheralTransport: NSObject, BLETransport {

    // MARK: - Identity

    private let identifier: UUID
    private unowned let centralManager: MWCentralManager

    // MARK: - CoreBluetooth state (nonisolated(unsafe) — see file header)

    nonisolated(unsafe) private var peripheral: CBPeripheral?
    nonisolated(unsafe) private var characteristics: [CBUUID: CBCharacteristic] = [:]
    /// Services still awaiting characteristic discovery. Set in didDiscoverServices,
    /// decremented in didDiscoverCharacteristicsFor. Connect succeeds when empty.
    nonisolated(unsafe) private var pendingServiceDiscoveries: Set<CBUUID> = []

    // MARK: - Pending continuations

    private var connectContinuation:    CheckedContinuation<Void, Error>?
    private var disconnectContinuation: CheckedContinuation<Void, Error>?
    private var readContinuations:  [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    // MARK: - Notification streams

    private var notifyContinuations: [CBUUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    // MARK: - Write queue (write-without-response back-pressure)
    //
    // Writes are sent immediately when canSendWriteWithoutResponse is true.
    // If the peripheral is not ready, data is queued and drained from
    // peripheralIsReady(toSendWriteWithoutResponse:).
    // We do NOT use an isWriting flag — that pattern only resets via
    // peripheralIsReady, which CoreBluetooth only calls when the buffer was
    // previously full. For our short commands (3–20 bytes) the buffer is
    // never full, so isWriting would stick at true and all writes after the
    // first would be silently dropped.

    private var writeQueue: [(Data, CBUUID, CBCharacteristicWriteType)] = []

    // MARK: - Init

    init(identifier: UUID, centralManager: MWCentralManager) {
        self.identifier = identifier
        self.centralManager = centralManager
    }

    // MARK: - BLETransport — scan (not supported per-device; use MetaWearScanner)

    func scan(for services: [CBUUID]?) -> AsyncStream<ScanResult> {
        AsyncStream { _ in }
    }

    // MARK: - BLETransport — connect / disconnect

    func connect(to id: UUID) async throws {
        mwLog("[BLE] PeripheralTransport connect: \(id)")
        // Ask the central manager to look up the peripheral and start connecting.
        // CBPeripheral stays inside MWCentralManager — it is never returned here.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            Task {
                do {
                    try await centralManager.requestConnect(identifier: id, transport: self)
                } catch {
                    // Peripheral not found — fail the continuation immediately.
                    self.connectContinuation?.resume(throwing: error)
                    self.connectContinuation = nil
                }
            }
        }
    }

    func disconnect() async throws {
        mwLog("[BLE] PeripheralTransport disconnect: \(identifier)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            disconnectContinuation = continuation
            Task { await centralManager.requestDisconnect(identifier: self.identifier) }
        }
    }

    // MARK: - BLETransport — write

    func write(_ data: Data, to characteristic: CBUUID, type: CBCharacteristicWriteType) async throws {
        guard let peripheral, let char = characteristics[characteristic] else {
            throw MWError.operationFailed("Characteristic \(characteristic) not available")
        }
        if type == .withResponse {
            try await withCheckedThrowingContinuation { continuation in
                writeContinuations[characteristic] = continuation
                peripheral.writeValue(data, for: char, type: type)
            }
        } else {
            enqueueWrite(data, char: char, type: type, peripheral: peripheral)
        }
    }

    // MARK: - BLETransport — read

    func read(from characteristic: CBUUID) async throws -> Data {
        guard let peripheral, let char = characteristics[characteristic] else {
            throw MWError.operationFailed("Characteristic \(characteristic) not available")
        }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuations[characteristic] = continuation
            peripheral.readValue(for: char)
        }
    }

    // MARK: - BLETransport — notifications

    func notifications(from characteristic: CBUUID) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else { return }
            Task {
                await self.beginNotifications(characteristic: characteristic, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.endNotifications(characteristic: characteristic) }
            }
        }
    }

    // MARK: - Callbacks from MWCentralManager

    /// Called synchronously (no Task) by MWCentralManager.handleConnect so that
    /// CBPeripheral never crosses an actor isolation boundary.
    nonisolated func handleConnected(peripheral: CBPeripheral) {
        mwLog("[BLE] PeripheralTransport handleConnected: \(peripheral.identifier), starting service discovery")
        self.peripheral = peripheral      // nonisolated(unsafe) — set before actor code runs
        peripheral.delegate = self
        peripheral.discoverServices([MWUUIDs.service, MWUUIDs.disService, MWUUIDs.batteryService])
    }

    func handleFailedToConnect(error: Error) {
        mwLog("[BLE] PeripheralTransport handleFailedToConnect: \(error.localizedDescription)")
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        peripheral = nil
    }

    func handleDisconnected(error: Error?) {
        mwLog("[BLE] PeripheralTransport handleDisconnected: error=\(error?.localizedDescription ?? "nil")")
        let err = error ?? MWError.operationFailed("Disconnected from \(identifier)")

        for continuation in notifyContinuations.values { continuation.finish(throwing: err) }
        notifyContinuations.removeAll()

        for continuation in readContinuations.values { continuation.resume(throwing: err) }
        readContinuations.removeAll()

        connectContinuation?.resume(throwing: err)
        connectContinuation = nil

        disconnectContinuation?.resume()
        disconnectContinuation = nil

        characteristics.removeAll()
        pendingServiceDiscoveries.removeAll()
        writeQueue.removeAll()
        peripheral = nil
    }

    // MARK: - Private helpers

    private func beginNotifications(
        characteristic: CBUUID,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        notifyContinuations[characteristic] = continuation
        guard let peripheral, let char = characteristics[characteristic] else { return }
        peripheral.setNotifyValue(true, for: char)
    }

    private func endNotifications(characteristic: CBUUID) {
        notifyContinuations.removeValue(forKey: characteristic)
        guard let peripheral, let char = characteristics[characteristic] else { return }
        peripheral.setNotifyValue(false, for: char)
    }

    private func enqueueWrite(
        _ data: Data, char: CBCharacteristic,
        type: CBCharacteristicWriteType, peripheral: CBPeripheral
    ) {
        guard peripheral.canSendWriteWithoutResponse else {
            writeQueue.append((data, char.uuid, type))
            return
        }
        peripheral.writeValue(data, for: char, type: type)
    }

    private func drainWriteQueue() {
        guard let peripheral else { return }
        while !writeQueue.isEmpty, peripheral.canSendWriteWithoutResponse {
            let (data, uuid, _) = writeQueue.removeFirst()
            guard let char = characteristics[uuid] else { continue }
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        }
    }

}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothPeripheralTransport: CBPeripheralDelegate {

    // Extract all non-Sendable values at the nonisolated boundary;
    // pass only Sendable types (CBUUID, Data, Error) into the actor.

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            mwLog("[BLE] didDiscoverServices error: \(error.localizedDescription)")
            Task { await self.failConnect(error: error) }
            return
        }
        let services = peripheral.services ?? []
        let serviceUUIDs = services.map { $0.uuid.uuidString }.joined(separator: ", ")
        mwLog("[BLE] didDiscoverServices: [\(serviceUUIDs)]")
        // Record which services we're waiting on before kicking off discovery.
        pendingServiceDiscoveries = Set(services.map { $0.uuid })
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            mwLog("[BLE] didDiscoverCharacteristics error for \(service.uuid): \(error.localizedDescription)")
            Task { await self.failConnect(error: error) }
            return
        }
        let charUUIDs = service.characteristics?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "none"
        mwLog("[BLE] didDiscoverCharacteristics for \(service.uuid): [\(charUUIDs)]")
        // Write directly to nonisolated(unsafe) storage — safe here because no
        // actor-isolated code is running until connectContinuation resumes.
        service.characteristics?.forEach { characteristics[$0.uuid] = $0 }
        pendingServiceDiscoveries.remove(service.uuid)
        if pendingServiceDiscoveries.isEmpty {
            mwLog("[BLE] All services discovered — succeeding connect")
            Task { await self.succeedConnect() }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        if let error {
            Task { await self.handleReadError(error, uuid: uuid) }
        } else {
            let data = characteristic.value ?? Data()
            Task { await self.handleValueUpdate(uuid: uuid, data: data) }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        Task { await self.handleWriteConfirmation(uuid: uuid, error: error) }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { await self.drainWriteQueue() }
    }

    // MARK: - Actor-isolated handlers (Sendable parameters only)

    private func succeedConnect() {
        mwLog("[BLE] succeedConnect")
        connectContinuation?.resume()
        connectContinuation = nil
    }

    private func failConnect(error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    private func handleValueUpdate(uuid: CBUUID, data: Data) {
        mwLog("[BLE] handleValueUpdate: \(uuid) \(data.count) bytes")
        if let continuation = readContinuations[uuid] {
            continuation.resume(returning: data)
            readContinuations.removeValue(forKey: uuid)
        } else {
            notifyContinuations[uuid]?.yield(data)
        }
    }

    private func handleReadError(_ error: Error, uuid: CBUUID) {
        readContinuations[uuid]?.resume(throwing: error)
        readContinuations.removeValue(forKey: uuid)
        notifyContinuations[uuid]?.finish(throwing: error)
    }

    private func handleWriteConfirmation(uuid: CBUUID, error: Error?) {
        if let error {
            writeContinuations[uuid]?.resume(throwing: error)
        } else {
            writeContinuations[uuid]?.resume()
        }
        writeContinuations.removeValue(forKey: uuid)
    }
}
