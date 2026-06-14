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
//    2. Declare this adapter `@unchecked Sendable` because Nordic delegates
//       and AsyncThrowingStream termination cross Swift-concurrency domains.
//       Mutable state is protected by `lock`, and cancellation aborts are
//       dispatched onto the same serial queue Nordic uses for delegate calls.
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

    private struct State {
        var continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation?
        var controller: DFUServiceController?
        var currentPart: Int = 1
        var totalParts: Int = 1
    }

    private let lock = NSLock()
    private var lockedState = State()

    private func withLockedState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&lockedState)
    }

    private func context() -> (
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation,
        currentPart: Int,
        totalParts: Int
    )? {
        withLockedState { state in
            guard let continuation = state.continuation else { return nil }
            return (continuation, state.currentPart, state.totalParts)
        }
    }

    private func yieldState(_ state: DFUProgress.State, percentComplete: Double = 0) {
        guard let context = context() else { return }
        context.continuation.yield(DFUProgress(
            state: state,
            percentComplete: percentComplete,
            currentPart: context.currentPart,
            totalParts: context.totalParts
        ))
    }

    private func yieldUploadProgress(
        part: Int,
        totalParts: Int,
        percentComplete: Int,
        bytesPerSecond: Double
    ) {
        let continuation = withLockedState { state in
            state.currentPart = part
            state.totalParts = totalParts
            return state.continuation
        }
        continuation?.yield(DFUProgress(
            state: .uploading,
            percentComplete: Double(percentComplete),
            currentPart: part,
            totalParts: totalParts,
            bytesPerSecond: bytesPerSecond
        ))
    }

    private func finish(throwing error: Error? = nil) {
        let continuation = withLockedState { state in
            let continuation = state.continuation
            state.continuation = nil
            state.controller = nil
            return continuation
        }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private func controllerForCancellation() -> DFUServiceController? {
        withLockedState { $0.controller }
    }

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
            self.withLockedState { state in
                state.continuation = cont
                state.controller = nil
                state.currentPart = 1
                state.totalParts = 1
            }

            // Cancellation support: terminating the stream from the consumer
            // side (e.g. the Task is cancelled) maps to Nordic's `abort()`.
            cont.onTermination = { [weak self, queue] reason in
                guard let self else { return }
                if case .cancelled = reason {
                    queue.async { [weak self] in
                        guard let self,
                              let controller = self.controllerForCancellation() else { return }
                        _ = controller.abort()
                    }
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

            let controller = initiator.start(targetWithIdentifier: targetIdentifier)
            self.withLockedState { state in
                state.controller = controller
            }
        }
    }
}

// MARK: - DFUServiceDelegate

extension DFUSession: DFUServiceDelegate {

    func dfuStateDidChange(to state: DFUState) {
        switch state {
        case .connecting:
            yieldState(.connecting)
        case .starting:
            yieldState(.starting)
        case .enablingDfuMode:
            // Nordic's "enablingDfuMode" — the buttonless DFU service is
            // being asked to reset into bootloader. We've already done the
            // MetaWear-specific handoff before reaching this delegate; this
            // case mostly fires for buttonless services we don't trigger.
            // Map to `.bootloaderHandoff` for visibility.
            yieldState(.bootloaderHandoff)
        case .uploading:
            // Real progress comes through `dfuProgressDidChange` —
            // `dfuStateDidChange(to: .uploading)` only fires once at the
            // start of the upload phase. Yield a 0% snapshot here so
            // observers see the state transition immediately.
            yieldState(.uploading)
        case .validating:
            yieldState(.validating, percentComplete: 100)
        case .disconnecting:
            yieldState(.disconnecting, percentComplete: 100)
        case .completed:
            yieldState(.completed, percentComplete: 100)
            finish()
        case .aborted:
            yieldState(.aborted)
            finish(throwing: MWFirmwareError.aborted)
        @unknown default:
            // Future Nordic library versions may add states. Don't yield
            // anything; wait for the next known state or for an error.
            break
        }
    }

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        finish(
            throwing: MWFirmwareError.dfuFailed(message: "\(error.rawValue): \(message)")
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
        yieldUploadProgress(
            part: part,
            totalParts: totalParts,
            percentComplete: progress,
            bytesPerSecond: currentSpeedBytesPerSecond
        )
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
