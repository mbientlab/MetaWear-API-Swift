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
        // 1. State check.
        try self._ensureFlashableState()

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

        // 5. Bootloader handoff, then a single-stage flash. The explicit-URL
        //    path has no catalog metadata, so no bootloader interlock applies
        //    here — callers flashing custom firmware are expected to know
        //    their board's bootloader.
        try await self._handoffToBootloader(continuation: continuation)
        try await self._flashStages(
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

    /// Flash one or more firmware images in sequence — bootloader first when
    /// the interlock demands it, then the application. Each stage is one
    /// Nordic DFU run; after a bootloader stage the board resets back into
    /// MetaBoot (there's no valid application to boot into yet).
    ///
    /// Progress from every stage is renumbered so observers see stage-level
    /// `currentPart`/`totalParts`, and `.completed` is suppressed for all but
    /// the final stage — only the whole sequence finishing means "done".
    fileprivate func _flashStages(
        _ stages: [DFUFirmware],
        targetIdentifier: UUID,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        let total = stages.count
        for (index, firmware) in stages.enumerated() {
            // A cancelled task must never start (or continue past) a Nordic
            // DFU pass — DFUSession.run fires initiator.start synchronously
            // before iteration can observe the cancellation.
            try Task.checkCancellation()
            let stage = index + 1
            let isLast = stage == total
            continuation.yield(DFUProgress(
                state: .scanning, currentPart: stage, totalParts: total
            ))
            do {
                try await _runDFUPass(
                    firmware: firmware, targetIdentifier: targetIdentifier,
                    stage: stage, of: total, isLast: isLast,
                    continuation: continuation
                )
            } catch MWFirmwareError.dfuFailed(let message)
                where message.contains("DFU Service not found") {
                // Nordic lost the reconnect race (pre-reboot window / stale
                // GATT). MetaBoot sits waiting after boot, so one delayed
                // retry per stage is safe.
                mwFirmwareLog("[DFU] service not found — retrying once after settle delay")
                try? await Task.sleep(for: .seconds(2))
                continuation.yield(DFUProgress(
                    state: .scanning, currentPart: stage, totalParts: total
                ))
                try await _runDFUPass(
                    firmware: firmware, targetIdentifier: targetIdentifier,
                    stage: stage, of: total, isLast: isLast,
                    continuation: continuation
                )
            }
            if !isLast {
                mwFirmwareLog("[DFU] stage \(stage)/\(total) flashed — waiting for reboot into MetaBoot")
                // Throwing sleep on purpose: cancellation between stages must
                // abort the sequence, not fall through into the next flash.
                try await Task.sleep(for: .milliseconds(2500))
            }
        }
    }

    /// One Nordic DFU attempt. `DFUSession` is single-use, so each pass gets
    /// a fresh session and queue.
    fileprivate func _runDFUPass(
        firmware: DFUFirmware,
        targetIdentifier: UUID,
        stage: Int,
        of total: Int,
        isLast: Bool,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
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
            // A non-final stage finishing is progress, not completion.
            if progress.state == .completed && !isLast { continue }
            guard total > 1 else {
                continuation.yield(progress)
                continue
            }
            continuation.yield(DFUProgress(
                state: progress.state,
                percentComplete: progress.percentComplete,
                currentPart: stage,
                totalParts: total,
                bytesPerSecond: progress.bytesPerSecond
            ))
        }
        // AsyncThrowingStream's next() returns nil on task cancellation
        // instead of throwing — a cancelled iteration must not read as
        // stage success (the next stage would flash a half-written board).
        if Task.isCancelled { throw MWFirmwareError.aborted }
    }

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

        continuation.yield(DFUProgress(state: .downloadingFirmware))
        let applicationURL = try await server.downloadFirmware(build)
        // Parse before tearing down BLE so a bad artifact bails out while
        // the board is still in application mode.
        let application = try Self._makeDFUFirmware(from: applicationURL)

        try self._ensureFlashableState()
        let targetIdentifier = self.identifier
        try await self._handoffToBootloader(continuation: continuation)

        var stages: [DFUFirmware] = []
        if build.requiredBootloader != nil {
            stages = try await self._bootloaderStagesIfNeeded(
                for: build,
                deviceInfo: info,
                server: server,
                targetIdentifier: targetIdentifier,
                continuation: continuation
            )
        }
        stages.append(application)
        try await self._flashStages(
            stages,
            targetIdentifier: targetIdentifier,
            continuation: continuation
        )
    }

    /// Read the installed bootloader from MetaBoot and, when it's older than
    /// the build's requirement, download the chain of catalog bootloaders
    /// that fixes it (bootloader builds declare requirements of their own,
    /// so one upgrade may need stepping stones).
    ///
    /// A failed PROBE degrades to a single-stage flash (pre-interlock
    /// behavior) rather than blocking the update: near-all boards in the
    /// field already run an adequate bootloader, and a flaky characteristic
    /// read shouldn't strand them. Cancellation is NOT a probe failure and
    /// is rethrown — a cancelled update must never proceed to flash. A
    /// confirmed-outdated bootloader with no catalog remedy throws
    /// `bootloaderUpgradeUnavailable`; catalog fetch errors propagate as
    /// themselves so a transient network blip doesn't masquerade as that
    /// terminal verdict.
    fileprivate func _bootloaderStagesIfNeeded(
        for build: MWFirmwareBuild,
        deviceInfo info: MWDeviceInformation,
        server: MWFirmwareServer,
        targetIdentifier: UUID,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws -> [DFUFirmware] {
        let installed: String
        do {
            installed = try await MetaBootProbe.readBootloaderVersion(
                identifier: targetIdentifier
            )
            mwFirmwareLog("[DFU] MetaBoot reports bootloader \(installed)")
        } catch is CancellationError {
            throw CancellationError()
        } catch MWFirmwareError.aborted {
            throw MWFirmwareError.aborted
        } catch {
            mwFirmwareLog("[DFU] ⚠️  bootloader probe failed (\(error.localizedDescription)) — flashing application only")
            return []
        }
        let bootloaders = try await server.availableBuilds(
            hardwareRev: info.hardwareRevision,
            modelNumber: info.modelNumber,
            buildFlavor: "bootloader"
        )
        let plan = try BootloaderInterlock.plan(
            installedBootloader: installed,
            requiredBootloader: build.requiredBootloader,
            availableBootloaders: bootloaders,
            hardwareRev: info.hardwareRevision
        )
        guard case .flashBootloadersFirst(let chain) = plan else {
            return []
        }
        mwFirmwareLog("[DFU] bootloader \(installed) < required \(build.requiredBootloader ?? "?") — staging \(chain.map(\.firmwareRev).joined(separator: " → "))")
        let total = chain.count + 1
        var firmwares: [DFUFirmware] = []
        for (index, bootloaderBuild) in chain.enumerated() {
            continuation.yield(DFUProgress(
                state: .downloadingFirmware,
                currentPart: index + 1,
                totalParts: total
            ))
            let url = try await server.downloadFirmware(bootloaderBuild)
            firmwares.append(try Self._makeDFUFirmware(from: url))
        }
        return firmwares
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
        // Re-stage under the source's filename: `_makeDFUFirmware` dispatches
        // on the extension, and the session's temp file ends in ".tmp", which
        // would be rejected as an invalid firmware container.
        return try MWFirmwareServer.stageDownload(
            tempURL: tempURL,
            filename: url.lastPathComponent
        )
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
