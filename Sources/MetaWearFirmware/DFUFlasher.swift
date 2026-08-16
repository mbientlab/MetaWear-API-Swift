//
//  DFUFlasher.swift
//  MetaWearFirmware
//
//  Extracted low-level DFU orchestration — the parts of the flash pipeline
//  that don't need a `MetaWearDevice` actor. Everything here works from
//  values (target UUID, firmware file URL, catalog build metadata).
//
//  Two call sites:
//    • `MetaWearDevice+DFU` — app-mode entry points, which do their own
//      handoff via `sendExpectingDisconnect(MWDebug.JumpToBootloader())`
//      then delegate here for the actual flashing.
//    • `MetaBootFirmwareUpdater` — public entry points for devices ALREADY
//      in bootloader mode; skip the handoff and go straight to flashing.
//
//  All members are `internal`; the module-level public API is exposed via
//  the two callers above.
//

import Foundation
@preconcurrency import NordicDFU

enum DFUFlasher {

    // MARK: - Flash stages

    /// Flash one or more firmware images in sequence — bootloader first when
    /// the interlock demands it, then the application. Each stage is one
    /// Nordic DFU run; after a bootloader stage the board resets back into
    /// MetaBoot (there's no valid application to boot into yet).
    ///
    /// Progress from every stage is renumbered so observers see stage-level
    /// `currentPart`/`totalParts`, and `.completed` is suppressed for all but
    /// the final stage — only the whole sequence finishing means "done".
    static func flashStages(
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
                try await runDFUPass(
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
                try await runDFUPass(
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
    static func runDFUPass(
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

    // MARK: - Firmware parsing / download

    static func makeDFUFirmware(from url: URL) throws -> DFUFirmware {
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

    static func downloadToLocal(
        _ url: URL,
        fetcher: MWFirmwareFetcher
    ) async throws -> URL {
        let (tempURL, response) = try await fetcher.download(from: url)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw MWFirmwareError.badServerResponse(status: response.statusCode)
        }
        // Re-stage under the source's filename: `makeDFUFirmware` dispatches
        // on the extension, and the session's temp file ends in ".tmp", which
        // would be rejected as an invalid firmware container.
        return try MWFirmwareServer.stageDownload(
            tempURL: tempURL,
            filename: url.lastPathComponent
        )
    }

    // MARK: - Bootloader interlock

    /// Read the installed bootloader from MetaBoot and, when it's older than
    /// the target build's requirement, download the chain of catalog
    /// bootloaders that fixes it (bootloader builds declare requirements of
    /// their own, so one upgrade may need stepping stones).
    ///
    /// A failed PROBE degrades to a single-stage flash (pre-interlock
    /// behaviour) rather than blocking the update: near-all boards in the
    /// field already run an adequate bootloader, and a flaky characteristic
    /// read shouldn't strand them. Cancellation is NOT a probe failure and
    /// is rethrown — a cancelled update must never proceed to flash. A
    /// confirmed-outdated bootloader with no catalog remedy throws
    /// `bootloaderUpgradeUnavailable`; catalog fetch errors propagate as
    /// themselves so a transient network blip doesn't masquerade as that
    /// terminal verdict.
    static func bootloaderStagesIfNeeded(
        for build: MWFirmwareBuild,
        hardwareRev: String,
        modelNumber: String,
        server: MWFirmwareServer,
        targetIdentifier: UUID,
        installedBootloader: String? = nil,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws -> [DFUFirmware] {
        let installed: String
        if let installedBootloader {
            installed = installedBootloader
            mwFirmwareLog("[DFU] MetaBoot bootloader supplied: \(installed)")
        } else {
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
        }
        let bootloaders = try await server.availableBuilds(
            hardwareRev: hardwareRev,
            modelNumber: modelNumber,
            buildFlavor: "bootloader"
        )
        let plan = try BootloaderInterlock.plan(
            installedBootloader: installed,
            requiredBootloader: build.requiredBootloader,
            availableBootloaders: bootloaders,
            hardwareRev: hardwareRev
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
            firmwares.append(try makeDFUFirmware(from: url))
        }
        return firmwares
    }
}
