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
    /// no events — unless `forceReinstall` is set, which flashes the latest
    /// build regardless (recovery path for a misbehaving board, or a clean
    /// reflash after experimentation).
    nonisolated func updateFirmwareToLatest(
        server: MWFirmwareServer = MWFirmwareServer(),
        forceReinstall: Bool = false
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
                        forceReinstall: forceReinstall,
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
        // 1. State check.
        try self._ensureFlashableState()

        // 2. Resolve the firmware URL to a local file. Remote URLs go
        //    through the fetcher; file:// URLs are used as-is.
        let localURL: URL
        if zipURL.isFileURL {
            localURL = zipURL
        } else {
            continuation.yield(DFUProgress(state: .downloadingFirmware))
            localURL = try await DFUFlasher.downloadToLocal(zipURL, fetcher: fetcher)
        }

        // 3. Build the DFUFirmware (zip vs bin/hex) before tearing down BLE
        //    so a parse failure bails out cleanly while we're still
        //    connected.
        let firmware = try DFUFlasher.makeDFUFirmware(from: localURL)

        // 4. Capture the identifier — we'll use it to address the
        //    bootloader-mode peripheral once BLE drops.
        let targetIdentifier = self.identifier

        // 5. Bootloader handoff, then a single-stage flash. The explicit-URL
        //    path has no catalog metadata, so no bootloader interlock applies
        //    here — callers flashing custom firmware are expected to know
        //    their board's bootloader.
        try await self._handoffToBootloader(continuation: continuation)
        try await DFUFlasher.flashStages(
            [firmware],
            targetIdentifier: targetIdentifier,
            continuation: continuation
        )
    }

    /// Mid-stream / mid-log / mid-download is unsafe (the user should stop
    /// those first) — but "not connected" is a different situation deserving
    /// a different error: BLE links drop silently (supervision timeouts),
    /// and telling the user to "stop streaming" when the board simply
    /// disconnected sends them debugging the wrong thing.
    fileprivate func _ensureFlashableState() throws {
        switch self.state {
        case .idle:
            break
        case .disconnected, .connecting:
            throw MWFirmwareError.operationFailed(
                "The board is not connected. Reconnect and try again."
            )
        default:
            throw MWFirmwareError.deviceNotIdle
        }
    }

    /// Send jump-to-bootloader and wait for the BOARD to drop the link as it
    /// reboots into MetaBoot. Cancelling the connection from our side raced
    /// the reboot: Nordic would reconnect to a board still running app-mode
    /// firmware and fail service discovery with "DFU Service not found" (302).
    fileprivate func _handoffToBootloader(
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        continuation.yield(DFUProgress(state: .bootloaderHandoff))
        try await self.sendExpectingDisconnect(MWDebug.JumpToBootloader())
        // Give MetaBoot time to finish booting and start advertising before
        // anything connects to it.
        try? await Task.sleep(for: .milliseconds(1500))
    }

    // MARK: - Flashing extracted
    //
    // `flashStages`, `runDFUPass`, `makeDFUFirmware`, `downloadToLocal`, and
    // `bootloaderStagesIfNeeded` moved to `DFUFlasher` so the MetaBoot-only
    // update path can share them without a `MetaWearDevice` instance. See
    // `DFUFlasher.swift`.

    /// Driver for `updateFirmwareToLatest(server:)`.
    ///
    /// Adds the bootloader interlock the explicit-URL path can't have: after
    /// the MetaBoot handoff, the on-board bootloader version is read from the
    /// bootloader's Device Information service and compared against the
    /// target build's `requiredBootloader`. An outdated bootloader turns the
    /// update into a two-stage flash (catalog "bootloader" flavor first, then
    /// the application), surfaced through `currentPart`/`totalParts`.
    fileprivate func _runUpdateToLatest(
        server: MWFirmwareServer,
        forceReinstall: Bool,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        guard let info = self.deviceInfo else {
            throw MWFirmwareError.operationFailed(
                "Device info not populated — call connect() before updateFirmwareToLatest()."
            )
        }

        continuation.yield(DFUProgress(state: .fetchingCatalog))
        let build: MWFirmwareBuild
        if forceReinstall {
            // Flash the latest build even when the board already runs it.
            build = try await server.latestBuild(
                hardwareRev: info.hardwareRevision,
                modelNumber: info.modelNumber
            )
        } else if let update = try await server.updateAvailable(
            currentRev: info.firmwareRevision,
            hardwareRev: info.hardwareRevision,
            modelNumber: info.modelNumber
        ) {
            build = update
        } else {
            // Already up to date. Finish with no events; caller can
            // distinguish "nothing to do" from "update completed" by
            // observing whether `.completed` was yielded.
            return
        }

        continuation.yield(DFUProgress(state: .downloadingFirmware))
        let applicationURL = try await server.downloadFirmware(build)
        // Parse before tearing down BLE so a bad artifact bails out while
        // the board is still in application mode.
        let application = try DFUFlasher.makeDFUFirmware(from: applicationURL)

        try self._ensureFlashableState()
        let targetIdentifier = self.identifier
        try await self._handoffToBootloader(continuation: continuation)

        var stages: [DFUFirmware] = []
        if build.requiredBootloader != nil {
            stages = try await DFUFlasher.bootloaderStagesIfNeeded(
                for: build,
                hardwareRev: info.hardwareRevision,
                modelNumber: info.modelNumber,
                server: server,
                targetIdentifier: targetIdentifier,
                continuation: continuation
            )
        }
        stages.append(application)
        try await DFUFlasher.flashStages(
            stages,
            targetIdentifier: targetIdentifier,
            continuation: continuation
        )
    }

}
