//
//  MetaWearDevice+DFU.swift
//  MetaWearFirmware
//
//  Public DFU API extension on `MetaWearDevice`. Three entry points:
//
//    • `checkForFirmwareUpdate(...)`        — does the catalog have something
//                                             newer than what's on the board?
//    • `updateFirmware(zipURL:)`            — flash an explicit firmware file.
//    • `updateFirmwareToLatest(...)`        — fetch latest from MbientLab CDN
//                                             and flash it.
//
//  All update entry points return `AsyncThrowingStream<DFUProgress, Error>`
//  so callers can drive a progress bar from the same iteration that catches
//  failure. Cancelling the stream's iterator (or the enclosing Task) aborts
//  the in-flight DFU — Nordic's library handles that cleanly.
//
//  Orchestration shape:
//    1. Verify the device is `.idle` (no in-flight stream/log/download).
//    2. Yield `.bootloaderHandoff`, send `[0xFE, 0x02]`, disconnect cleanly.
//    3. Construct `DFUFirmware` from the zip / bin URL.
//    4. Hand off to `DFUSession`, forwarding every `DFUProgress` event up.
//    5. When `DFUSession` finishes, the device is back in app mode but our
//       in-memory device-info / module map is stale. The caller is
//       responsible for `connect()`-ing again.
//

import Foundation
@preconcurrency import NordicDFU
import MetaWear

public extension MetaWearDevice {

    // MARK: - Update check

    /// Check whether the MbientLab catalog has a firmware build newer than
    /// what's currently on the device. Returns `nil` if the device is
    /// already up to date. The device must be connected (so `deviceInfo` is
    /// populated) before this call.
    func checkForFirmwareUpdate(
        server: MWFirmwareServer = MWFirmwareServer()
    ) async throws -> MWFirmwareBuild? {
        guard let info = self.deviceInfo else {
            throw MWFirmwareError.operationFailed(
                "Device info not populated — call connect() before checkForFirmwareUpdate()."
            )
        }
        return try await server.updateAvailable(
            currentRev: info.firmwareRevision,
            hardwareRev: info.hardwareRevision,
            modelNumber: info.modelNumber
        )
    }

    // MARK: - Update from explicit zip URL (scope `a`)

    /// Flash the firmware at `zipURL` onto the connected device.
    ///
    /// The URL can be a remote `https://` URL (the orchestrator downloads
    /// it via the supplied `fetcher`), or a `file://` URL pointing at a
    /// firmware file already on disk.
    ///
    /// Accepted file extensions:
    ///   • `.zip` — Nordic DFU distribution package (preferred). Contains
    ///              the firmware binary plus a signed init packet, processed
    ///              by Nordic's library.
    ///   • `.bin` / `.hex` — raw application image, no init packet. Older
    ///              MetaWear firmware shipped this way.
    ///
    /// - Note: The device transitions to `.disconnected` mid-flight (board
    ///   reboots into bootloader). When the returned stream finishes
    ///   normally, the board is back in app mode but our local actor's
    ///   `state` / `deviceInfo` / `modules` cache is stale — call
    ///   `connect()` again to refresh.
    nonisolated func updateFirmware(
        zipURL: URL,
        fetcher: MWFirmwareFetcher = URLSessionFetcher()
    ) -> AsyncThrowingStream<DFUProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(
                        throwing: MWFirmwareError.operationFailed("Device deallocated.")
                    )
                    return
                }
                do {
                    try await self._runFirmwareUpdate(
                        zipURL: zipURL,
                        fetcher: fetcher,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Update to catalog-latest (scope `b`)

    /// Fetch the latest firmware from MbientLab's release catalog and flash
    /// it. If the device is already on the latest, the stream finishes with
    /// no events.
    nonisolated func updateFirmwareToLatest(
        server: MWFirmwareServer = MWFirmwareServer()
    ) -> AsyncThrowingStream<DFUProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(
                        throwing: MWFirmwareError.operationFailed("Device deallocated.")
                    )
                    return
                }
                do {
                    try await self._runUpdateToLatest(
                        server: server,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Private orchestration (actor-isolated)

extension MetaWearDevice {

    /// Driver for `updateFirmware(zipURL:)`.
    /// Runs every step on the actor so it stays serialised against any
    /// other device operation that might be queued.
    fileprivate func _runFirmwareUpdate(
        zipURL: URL,
        fetcher: MWFirmwareFetcher,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        // 1. Idle check. Mid-stream / mid-log / mid-download is unsafe; the
        //    user should stop those first.
        guard case .idle = self.state else {
            throw MWFirmwareError.deviceNotIdle
        }

        // 2. Resolve the firmware URL to a local file. Remote URLs go
        //    through the fetcher; file:// URLs are used as-is.
        let localURL: URL
        if zipURL.isFileURL {
            localURL = zipURL
        } else {
            continuation.yield(DFUProgress(state: .downloadingFirmware))
            localURL = try await Self._downloadToLocal(zipURL, fetcher: fetcher)
        }

        // 3. Build the DFUFirmware (zip vs bin/hex) before tearing down BLE
        //    so a parse failure bails out cleanly while we're still
        //    connected.
        let firmware = try Self._makeDFUFirmware(from: localURL)

        // 4. Capture the identifier — we'll use it to address the
        //    bootloader-mode peripheral once BLE drops.
        let targetIdentifier = self.identifier

        // 5. Bootloader handoff: jump-to-bootloader + clean local
        //    disconnect. The board reboots into MetaBoot mode and re-
        //    advertises with the Nordic DFU service.
        continuation.yield(DFUProgress(state: .bootloaderHandoff))
        try await self.send(MWDebug.JumpToBootloader())
        // The board's reboot drops the BLE link asynchronously; tear down
        // our actor's view of the connection so subsequent code doesn't
        // interact with a half-dead transport.
        try? await self.disconnect()

        // 6. Hand off to Nordic. DFUSession runs on its own dispatch queue
        //    and yields events into our continuation.
        continuation.yield(DFUProgress(state: .scanning))
        let session = DFUSession()
        let queue = DispatchQueue(
            label: "com.metawear.firmware.dfu.\(targetIdentifier.uuidString)",
            qos: .userInitiated
        )
        let dfuStream = session.run(
            firmware: firmware,
            targetIdentifier: targetIdentifier,
            queue: queue
        )
        for try await progress in dfuStream {
            continuation.yield(progress)
        }
    }

    /// Driver for `updateFirmwareToLatest(server:)`.
    fileprivate func _runUpdateToLatest(
        server: MWFirmwareServer,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        guard let info = self.deviceInfo else {
            throw MWFirmwareError.operationFailed(
                "Device info not populated — call connect() before updateFirmwareToLatest()."
            )
        }

        continuation.yield(DFUProgress(state: .fetchingCatalog))
        guard let build = try await server.updateAvailable(
            currentRev: info.firmwareRevision,
            hardwareRev: info.hardwareRevision,
            modelNumber: info.modelNumber
        ) else {
            // Already up to date. Finish with no events; caller can
            // distinguish "nothing to do" from "update completed" by
            // observing whether `.completed` was yielded.
            return
        }

        // The orchestrator below downloads the firmware, but yield this
        // event first so the caller sees the phase transition.
        continuation.yield(DFUProgress(state: .downloadingFirmware))
        let localURL = try await server.downloadFirmware(build)

        // Delegate to the explicit-URL path. _runFirmwareUpdate also
        // yields .downloadingFirmware for remote URLs; calling with the
        // file:// URL we just produced bypasses the duplicate yield.
        try await self._runFirmwareUpdate(
            zipURL: localURL,
            fetcher: URLSessionFetcher(),
            continuation: continuation
        )
    }

    // MARK: - Helpers

    fileprivate static func _downloadToLocal(
        _ url: URL,
        fetcher: MWFirmwareFetcher
    ) async throws -> URL {
        let (tempURL, response) = try await fetcher.download(from: url)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw MWFirmwareError.badServerResponse(status: response.statusCode)
        }
        return tempURL
    }

    fileprivate static func _makeDFUFirmware(from url: URL) throws -> DFUFirmware {
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "zip":
                return try DFUFirmware(urlToZipFile: url)
            case "bin", "hex":
                return try DFUFirmware(
                    urlToBinOrHexFile: url,
                    urlToDatFile: nil,
                    type: .application
                )
            default:
                throw MWFirmwareError.invalidFirmwareFile(url)
            }
        } catch let mwError as MWFirmwareError {
            throw mwError
        } catch {
            // Nordic's parser throws its own errors (zip extraction failure,
            // missing manifest, etc.). Wrap them so callers see one error
            // taxonomy.
            throw MWFirmwareError.invalidFirmwareFile(url)
        }
    }
}
