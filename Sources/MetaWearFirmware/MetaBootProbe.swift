//
//  MetaBootProbe.swift
//  MetaWearFirmware
//
//  Reads Device Information Service characteristics from a MetaWear that has
//  already rebooted into MetaBoot (bootloader) mode.
//
//  In MetaBoot mode the standard Device Information Service's Firmware
//  Revision characteristic (0x2A26) reports the BOOTLOADER version rather
//  than the application firmware version — and MetaBoot is the only place
//  the bootloader version is readable at all; application-mode firmware
//  doesn't expose it. Hardware Revision (0x2A27) and Model Number (0x2A24)
//  are readable in both modes and identify the physical board, which the
//  app-side "connect to a MetaBoot device" flow needs to look up firmware
//  from the MbientLab catalog without having the MetaWear service.
//
//  This is a deliberately tiny, single-shot CoreBluetooth client: the core
//  SDK's transport can't be reused because its connect sequence requires the
//  MetaWear command service, which MetaBoot doesn't advertise. Like
//  `DFUSession`, it bridges a delegate-based API into async/await and is
//  `@unchecked Sendable` with all mutable state behind a lock.
//

import Foundation
@preconcurrency import CoreBluetooth

// MARK: - Public: MetaBootDeviceInfo

/// A snapshot of the three Device Information Service strings a MetaWear
/// exposes while running in MetaBoot mode.
///
/// - Important: `bootloaderVersion` is the string reported by the Firmware
///   Revision characteristic (0x2A26). While the board is in MetaBoot mode
///   this describes the *bootloader*, not the application firmware — the
///   application partition may be present, missing, or a different version.
public struct MetaBootDeviceInfo: Sendable, Equatable {

    /// From `2A27` — same physical hardware descriptor exposed in
    /// application mode (e.g. `"0.4"`).
    public let hardwareRevision: String

    /// From `2A24` — same model number exposed in application mode
    /// (e.g. `"5"` for MetaMotion R, `"8"` for MetaMotion S).
    public let modelNumber: String

    /// From `2A26` — reports the BOOTLOADER version while the board is in
    /// MetaBoot mode, not the application firmware version.
    public let bootloaderVersion: String

    public init(
        hardwareRevision: String,
        modelNumber: String,
        bootloaderVersion: String
    ) {
        self.hardwareRevision = hardwareRevision
        self.modelNumber = modelNumber
        self.bootloaderVersion = bootloaderVersion
    }

    /// Connect to the MetaBoot-mode peripheral with `identifier`, read the
    /// three Device Information Service strings, and disconnect.
    ///
    /// - Note: The board must already be in MetaBoot mode and advertising
    ///   (e.g. after a jump-to-bootloader handoff, or a board that has been
    ///   sitting in MetaBoot because the last application flash didn't take).
    public static func read(
        identifier: UUID,
        timeout: TimeInterval = 10
    ) async throws -> MetaBootDeviceInfo {
        let results = try await MetaBootProbe.readCharacteristics(
            identifier: identifier,
            characteristics: [
                MetaBootProbe.hardwareRevision,
                MetaBootProbe.modelNumber,
                MetaBootProbe.firmwareRevision
            ],
            timeout: timeout
        )
        guard let hardware = results[MetaBootProbe.hardwareRevision.uuidString],
              let model = results[MetaBootProbe.modelNumber.uuidString],
              let firmware = results[MetaBootProbe.firmwareRevision.uuidString] else {
            // Delegates read every requested characteristic before finishing;
            // a missing entry means the probe reported success on a partial
            // read, which shouldn't happen. Surface it as a clear error so
            // a future regression is loud.
            throw MWFirmwareError.operationFailed(
                "MetaBoot device info read returned an incomplete result."
            )
        }
        return MetaBootDeviceInfo(
            hardwareRevision: hardware,
            modelNumber: model,
            bootloaderVersion: firmware
        )
    }
}

// MARK: - Internal probe

final class MetaBootProbe: NSObject, @unchecked Sendable {

    // MARK: - Characteristic UUIDs (module-internal so `MetaBootDeviceInfo` can reference them)

    static let deviceInformationService = CBUUID(string: "180A")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let hardwareRevision = CBUUID(string: "2A27")
    static let modelNumber = CBUUID(string: "2A24")

    // MARK: - State

    private let lock = NSLock()
    // Result dict is keyed by `CBUUID.uuidString` (not the CBUUID itself)
    // because CBUUID is not `Sendable` in the CoreBluetooth headers; a
    // `[CBUUID: String]` result crossing the continuation boundary trips
    // Swift 6's SendingRisksDataRace check. Callers translate back with
    // `CBUUID.uuidString` at both ends of the API.
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// Sticky terminal flag, distinct from `continuation == nil`: it lets a
    /// cancellation that lands BEFORE the continuation is registered still
    /// take effect (the registration path checks it), and lets delegate
    /// callbacks that race teardown bail out early.
    private var isFinished = false
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private let queue = DispatchQueue(label: "com.metawear.firmware.metabootprobe", qos: .userInitiated)
    private let targetIdentifier: UUID
    private let characteristics: [CBUUID]
    private var characteristicsToRead: Set<CBUUID>
    private var results: [String: String] = [:]

    private init(targetIdentifier: UUID, characteristics: [CBUUID]) {
        self.targetIdentifier = targetIdentifier
        self.characteristics = characteristics
        self.characteristicsToRead = Set(characteristics)
    }

    // MARK: - Public entry points

    /// Convenience: read only the bootloader version (Firmware Revision
    /// characteristic). Preserves the historic single-value shape that the
    /// `BootloaderInterlock` uses.
    static func readBootloaderVersion(
        identifier: UUID,
        timeout: TimeInterval = 10
    ) async throws -> String {
        let results = try await readCharacteristics(
            identifier: identifier,
            characteristics: [firmwareRevision],
            timeout: timeout
        )
        guard let value = results[firmwareRevision.uuidString] else {
            throw MWFirmwareError.operationFailed(
                "MetaBoot bootloader version read returned no value."
            )
        }
        return value
    }

    /// Read the given DIS characteristics from a MetaBoot-mode peripheral in
    /// one connection. Reads are issued sequentially in the order supplied
    /// so a single characteristic failure (missing / unreadable) fails the
    /// whole probe cleanly.
    static func readCharacteristics(
        identifier: UUID,
        characteristics: [CBUUID],
        timeout: TimeInterval = 10
    ) async throws -> [String: String] {
        try Task.checkCancellation()
        let probe = MetaBootProbe(
            targetIdentifier: identifier,
            characteristics: characteristics
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                probe.start(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            probe.finish(throwing: MWFirmwareError.aborted)
        }
    }

    // MARK: - Lifecycle

    private func start(
        continuation: CheckedContinuation<[String: String], Error>,
        timeout: TimeInterval
    ) {
        lock.lock()
        if isFinished {
            // Cancellation won the race before registration; don't touch
            // CoreBluetooth at all.
            lock.unlock()
            continuation.resume(throwing: MWFirmwareError.aborted)
            return
        }
        self.continuation = continuation
        lock.unlock()

        // Creating the central on our queue delivers the poweredOn state
        // callback there; connection begins in centralManagerDidUpdateState.
        // Store it under the lock — finish() can run concurrently from the
        // cancellation handler on another thread.
        let manager = CBCentralManager(delegate: self, queue: queue)
        lock.lock()
        let finishedMeanwhile = isFinished
        if !finishedMeanwhile { central = manager }
        lock.unlock()
        if finishedMeanwhile {
            // finish() already resumed the continuation; the discarded
            // manager never connected (delegate callbacks check isFinished).
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(throwing: MWFirmwareError.operationFailed(
                "Timed out reading Device Information from MetaBoot."
            ))
        }
    }

    /// True once the probe has reached its terminal state; delegate callbacks
    /// use this to stop touching CoreBluetooth after teardown.
    private var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    /// One-shot completion: resume the continuation exactly once and tear
    /// down all CoreBluetooth state, whichever path (value, error, timeout,
    /// cancellation) gets here first.
    private func finish(
        returning value: [String: String]? = nil,
        throwing error: Error? = nil
    ) {
        lock.lock()
        let alreadyFinished = isFinished
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let central = self.central
        let peripheral = self.peripheral
        self.central = nil
        self.peripheral = nil
        lock.unlock()
        guard !alreadyFinished, let continuation else { return }
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        if let value {
            continuation.resume(returning: value)
        } else {
            continuation.resume(throwing: error ?? MWFirmwareError.operationFailed(
                "MetaBoot Device Information read failed."
            ))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MetaBootProbe: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // A probe torn down by cancellation may still receive this callback
        // from its discarded manager — never start connecting after teardown.
        guard !hasFinished else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                finish(throwing: MWFirmwareError.operationFailed(
                    "Bluetooth unavailable while reading Device Information from MetaBoot."
                ))
            }
            return
        }
        // The system already knows this identifier from the pre-handoff
        // connection; retrieval works even before a fresh advertisement.
        guard let target = central.retrievePeripherals(withIdentifiers: [targetIdentifier]).first else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot peripheral not found for Device Information read."
            ))
            return
        }
        lock.lock()
        peripheral = target
        lock.unlock()
        target.delegate = self
        central.connect(target)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.deviceInformationService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finish(throwing: MWFirmwareError.operationFailed(
            "Couldn't connect to MetaBoot: \(error?.localizedDescription ?? "unknown error")"
        ))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // If the connection dropped after all reads succeeded we've already
        // finished — the `hasFinished` check would gate the throw. But the
        // finish() re-check catches races: if the peripheral disconnected
        // between the last didUpdateValueFor and our own cancelPeripheralConnection,
        // finish() will no-op the second call.
        guard !hasFinished else { return }
        finish(throwing: MWFirmwareError.operationFailed(
            "MetaBoot disconnected during Device Information read."
        ))
    }
}

// MARK: - CBPeripheralDelegate

extension MetaBootProbe: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(
                where: { $0.uuid == Self.deviceInformationService }
              ) else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot has no Device Information service."
            ))
            return
        }
        peripheral.discoverCharacteristics(characteristics, for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let discovered = service.characteristics else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot characteristic discovery failed: \(error?.localizedDescription ?? "unknown")"
            ))
            return
        }
        // Verify every requested characteristic is present. Missing a needed
        // characteristic is a firmware/hardware mismatch we can't work
        // around — surface it clearly instead of silently returning partial
        // data.
        let discoveredUUIDs = Set(discovered.map(\.uuid))
        let missing = Set(characteristics).subtracting(discoveredUUIDs)
        if !missing.isEmpty {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot is missing expected DIS characteristics: \(missing.map(\.uuidString).joined(separator: ", "))"
            ))
            return
        }
        // Kick off the first read; subsequent reads chain from
        // didUpdateValueFor once the previous value lands.
        guard let first = characteristics.first,
              let firstChar = discovered.first(where: { $0.uuid == first }) else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot characteristic list is empty."
            ))
            return
        }
        peripheral.readValue(for: firstChar)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard !hasFinished else { return }
        guard error == nil,
              let data = characteristic.value,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            finish(throwing: MWFirmwareError.operationFailed(
                "Unreadable value for \(characteristic.uuid.uuidString) from MetaBoot."
            ))
            return
        }
        lock.lock()
        results[characteristic.uuid.uuidString] = value
        characteristicsToRead.remove(characteristic.uuid)
        let remaining = characteristicsToRead
        let allResults = results
        lock.unlock()
        if remaining.isEmpty {
            finish(returning: allResults)
            return
        }
        // Find the next characteristic to read from the ordered list,
        // skipping ones already read. Order matters because callers may
        // want stable log output; the set difference alone doesn't preserve
        // order.
        guard let nextUUID = characteristics.first(where: { remaining.contains($0) }),
              let service = peripheral.services?.first(where: { $0.uuid == Self.deviceInformationService }),
              let nextChar = service.characteristics?.first(where: { $0.uuid == nextUUID }) else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot next-characteristic lookup failed after reading \(characteristic.uuid.uuidString)."
            ))
            return
        }
        peripheral.readValue(for: nextChar)
    }
}
