//
//  MetaBootProbe.swift
//  MetaWearFirmware
//
//  Reads the bootloader version from a MetaWear that has already rebooted
//  into MetaBoot (bootloader) mode.
//
//  In MetaBoot mode the standard Device Information Service's Firmware
//  Revision characteristic (0x2A26) reports the BOOTLOADER version rather
//  than the application firmware version — and MetaBoot is the only place
//  the bootloader version is readable at all; application-mode firmware
//  doesn't expose it. The bootloader interlock uses this to decide whether
//  a bootloader-flavor flash must precede the application flash.
//
//  This is a deliberately tiny, single-shot CoreBluetooth client: the core
//  SDK's transport can't be reused because its connect sequence requires the
//  MetaWear command service, which MetaBoot doesn't advertise. Like
//  `DFUSession`, it bridges a delegate-based API into async/await and is
//  `@unchecked Sendable` with all mutable state behind a lock.
//

import Foundation
@preconcurrency import CoreBluetooth

final class MetaBootProbe: NSObject, @unchecked Sendable {

    private static let deviceInformationService = CBUUID(string: "180A")
    private static let firmwareRevision = CBUUID(string: "2A26")

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    /// Sticky terminal flag, distinct from `continuation == nil`: it lets a
    /// cancellation that lands BEFORE the continuation is registered still
    /// take effect (the registration path checks it), and lets delegate
    /// callbacks that race teardown bail out early.
    private var isFinished = false
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private let queue = DispatchQueue(label: "com.metawear.firmware.metabootprobe", qos: .userInitiated)
    private let targetIdentifier: UUID

    private init(targetIdentifier: UUID) {
        self.targetIdentifier = targetIdentifier
    }

    /// Connect to the MetaBoot-mode peripheral with `identifier`, read the
    /// Firmware Revision string (= bootloader version), and disconnect.
    ///
    /// - Note: The board must already be in MetaBoot mode and advertising —
    ///   call only after the jump-to-bootloader handoff has completed.
    static func readBootloaderVersion(
        identifier: UUID,
        timeout: TimeInterval = 10
    ) async throws -> String {
        try Task.checkCancellation()
        let probe = MetaBootProbe(targetIdentifier: identifier)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                probe.start(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            probe.finish(throwing: MWFirmwareError.aborted)
        }
    }

    private func start(
        continuation: CheckedContinuation<String, Error>,
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
                "Timed out reading the bootloader version from the device."
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
    private func finish(returning value: String? = nil, throwing error: Error? = nil) {
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
                "Bootloader version read failed."
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
                    "Bluetooth unavailable while reading the bootloader version."
                ))
            }
            return
        }
        // The system already knows this identifier from the pre-handoff
        // connection; retrieval works even before a fresh advertisement.
        guard let target = central.retrievePeripherals(withIdentifiers: [targetIdentifier]).first else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot peripheral not found for bootloader version read."
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
        finish(throwing: MWFirmwareError.operationFailed(
            "MetaBoot disconnected during bootloader version read."
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
        peripheral.discoverCharacteristics([Self.firmwareRevision], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(
                where: { $0.uuid == Self.firmwareRevision }
              ) else {
            finish(throwing: MWFirmwareError.operationFailed(
                "MetaBoot exposes no Firmware Revision characteristic."
            ))
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              let data = characteristic.value,
              let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            finish(throwing: MWFirmwareError.operationFailed(
                "Unreadable bootloader version value."
            ))
            return
        }
        finish(returning: version)
    }
}
