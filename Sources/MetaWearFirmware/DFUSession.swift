//
//  DFUSession.swift
//  MetaWearFirmware
//
//  Adapter that wraps the Nordic DFU library's delegate-based API into a
//  Swift Concurrency `AsyncThrowingStream<DFUProgress, Error>`.
//
//  The Nordic library (4.16.0) is still @objc / delegate-based and is NOT
//  Swift 6 strict-concurrency aware — it has zero `Sendable` annotations,
//  declares `swiftLanguageVersions: [.v5]`, and calls delegate methods from
//  its internal serial dispatch queue. We:
//
//    1. Import it `@preconcurrency` so its types cross our actor boundaries
//       without warnings.
//    2. Declare this adapter `@unchecked Sendable` because the only mutable
//       state (`continuation`, `controller`) is written once in `run(...)`
//       before the Nordic queue starts firing delegates, and only read after
//       that. The library's internal serialisation provides happens-before.
//    3. Hand the continuation a `Sendable` AsyncThrowingStream which is safe
//       to `yield` from any thread.
//
//  This file has no unit-test coverage — it's purely a wrapper around the
//  Nordic library, which itself can only be exercised on real hardware.
//

import Foundation
import CoreBluetooth
@preconcurrency import NordicDFU

/// Owns one Nordic DFU run from start to finish.
///
/// Lifecycle: create → call `run(...)` → consume the returned stream until
/// it finishes or throws → discard. Reusing the same instance for a second
/// run is undefined; create a fresh `DFUSession` each time.
final class DFUSession: NSObject, @unchecked Sendable {

    private var continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation?
    private var controller: DFUServiceController?

    // Track multi-part progress so we can echo it on every yield, including
    // the non-`.uploading` phases that Nordic's progress delegate never
    // calls back for.
    private var currentPart: Int = 1
    private var totalParts: Int = 1

    /// Kick off the DFU and stream `DFUProgress` events.
    ///
    /// - Parameters:
    ///   - firmware:         A `DFUFirmware` already constructed from a zip
    ///                       or bin/hex URL by the orchestrator.
    ///   - targetIdentifier: The bootloader-mode peripheral's UUID. The
    ///                       MetaWear's CoreBluetooth identifier persists
    ///                       across the bootloader handoff (same hardware
    ///                       MAC), so the same UUID the device used in
    ///                       application mode also addresses it post-handoff.
    ///   - queue:            DispatchQueue Nordic uses for its internal BLE
    ///                       work AND for invoking our delegate methods.
    ///                       Pass a serial queue dedicated to this session.
    /// - Returns: A stream that yields `DFUProgress` until completion, then
    ///   finishes; or finishes throwing on transport / validation errors.
    func run(
        firmware: DFUFirmware,
        targetIdentifier: UUID,
        queue: DispatchQueue
    ) -> AsyncThrowingStream<DFUProgress, Error> {
        AsyncThrowingStream { [self] cont in
            self.continuation = cont

            // Cancellation support: terminating the stream from the consumer
            // side (e.g. the Task is cancelled) maps to Nordic's `abort()`.
            cont.onTermination = { [weak self] reason in
                guard let self else { return }
                if case .cancelled = reason {
                    _ = self.controller?.abort()
                }
            }

            let initiator = DFUServiceInitiator(queue: queue).with(firmware: firmware)
            initiator.delegate = self
            initiator.progressDelegate = self
            initiator.logger = self
            // The MetaWear bootloader exposes the standard Nordic DFU service
            // (UUID `00001530-...`). `forceDfu` skips the library's check
            // for the additional MetaWear DIS service that's only present in
            // application mode, which would otherwise abort here.
            initiator.forceDfu = true

            self.controller = initiator.start(targetWithIdentifier: targetIdentifier)
        }
    }
}

// MARK: - DFUServiceDelegate

extension DFUSession: DFUServiceDelegate {

    func dfuStateDidChange(to state: DFUState) {
        guard let cont = continuation else { return }
        switch state {
        case .connecting:
            cont.yield(DFUProgress(
                state: .connecting,
                currentPart: currentPart, totalParts: totalParts
            ))
        case .starting:
            cont.yield(DFUProgress(
                state: .starting,
                currentPart: currentPart, totalParts: totalParts
            ))
        case .enablingDfuMode:
            // Nordic's "enablingDfuMode" — the buttonless DFU service is
            // being asked to reset into bootloader. We've already done the
            // MetaWear-specific handoff before reaching this delegate; this
            // case mostly fires for buttonless services we don't trigger.
            // Map to `.bootloaderHandoff` for visibility.
            cont.yield(DFUProgress(
                state: .bootloaderHandoff,
                currentPart: currentPart, totalParts: totalParts
            ))
        case .uploading:
            // Real progress comes through `dfuProgressDidChange` —
            // `dfuStateDidChange(to: .uploading)` only fires once at the
            // start of the upload phase. Yield a 0% snapshot here so
            // observers see the state transition immediately.
            cont.yield(DFUProgress(
                state: .uploading,
                percentComplete: 0,
                currentPart: currentPart, totalParts: totalParts
            ))
        case .validating:
            cont.yield(DFUProgress(
                state: .validating,
                percentComplete: 100,
                currentPart: currentPart, totalParts: totalParts
            ))
        case .disconnecting:
            cont.yield(DFUProgress(
                state: .disconnecting,
                percentComplete: 100,
                currentPart: currentPart, totalParts: totalParts
            ))
        case .completed:
            cont.yield(DFUProgress(
                state: .completed,
                percentComplete: 100,
                currentPart: currentPart, totalParts: totalParts
            ))
            cont.finish()
        case .aborted:
            cont.yield(DFUProgress(
                state: .aborted,
                currentPart: currentPart, totalParts: totalParts
            ))
            cont.finish(throwing: MWFirmwareError.aborted)
        @unknown default:
            // Future Nordic library versions may add states. Don't yield
            // anything; wait for the next known state or for an error.
            break
        }
    }

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        continuation?.finish(
            throwing: MWFirmwareError.dfuFailed(
                message: "\(error.rawValue): \(message)"
            )
        )
    }
}

// MARK: - DFUProgressDelegate

extension DFUSession: DFUProgressDelegate {

    func dfuProgressDidChange(
        for part: Int,
        outOf totalParts: Int,
        to progress: Int,
        currentSpeedBytesPerSecond: Double,
        avgSpeedBytesPerSecond: Double
    ) {
        self.currentPart = part
        self.totalParts = totalParts
        continuation?.yield(DFUProgress(
            state: .uploading,
            percentComplete: Double(progress),
            currentPart: part,
            totalParts: totalParts,
            bytesPerSecond: currentSpeedBytesPerSecond
        ))
    }
}

// MARK: - LoggerDelegate

extension DFUSession: LoggerDelegate {

    /// Forward Nordic's library logs to the MetaWear console logger so DFU
    /// activity shows up in the same place as the rest of the SDK's wire
    /// log. We swallow `.debug` and `.verbose` to keep output readable;
    /// raise the floor here if you need more detail while diagnosing.
    func logWith(_ level: NordicDFU.LogLevel, message: String) {
        switch level {
        case .debug, .verbose:
            return
        case .info, .application:
            mwFirmwareLog("[DFU] \(message)")
        case .warning:
            mwFirmwareLog("[DFU] ⚠️  \(message)")
        case .error:
            mwFirmwareLog("[DFU] ❌  \(message)")
        @unknown default:
            mwFirmwareLog("[DFU] \(message)")
        }
    }
}

// MARK: - Logging hook
//
// The MetaWear core SDK has its own `mwLog` shim, but it's internal to that
// module. Mirror it locally so this file's logs are consistent without
// reaching into the core target.

@inlinable
func mwFirmwareLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
