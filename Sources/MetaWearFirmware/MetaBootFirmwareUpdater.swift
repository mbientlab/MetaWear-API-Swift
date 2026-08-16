//
//  MetaBootFirmwareUpdater.swift
//  MetaWearFirmware
//
//  Public DFU entry points for a MetaWear device that is ALREADY in MetaBoot
//  (bootloader) mode. Unlike `MetaWearDevice.updateFirmware(...)`, these
//  don't send the jump-to-bootloader command — the caller has discovered the
//  device via `MetaWearScanner.discoveredMetaBootDevices` (scanner in
//  `.metaBoot` mode) and holds only its `UUID`, not a `MetaWearDevice`.
//
//  Two entry points:
//    • `updateFirmware(identifier:zipURL:)`    — explicit zip / bin / hex.
//    • `updateFirmwareToLatest(identifier:)`   — read hw + model from
//                                                MetaBoot DIS, look up
//                                                latest on the catalog,
//                                                run the interlock, flash.
//
//  Both return an `AsyncThrowingStream<DFUProgress, Error>`. Because the
//  device is already in MetaBoot mode, the first yielded state is
//  `.scanning` or `.fetchingCatalog` (never `.bootloaderHandoff`). Common
//  use case: recovering a board that has been stuck in MetaBoot because a
//  previous flash didn't complete, or a user-triggered rescue flash from
//  the app's connection screen with MetaBoot mode enabled.
//

import Foundation

public enum MetaBootFirmwareUpdater {

    // MARK: - Update from explicit zip URL

    /// Flash the firmware at `zipURL` onto a device already in MetaBoot
    /// mode. `identifier` is the CoreBluetooth peripheral UUID observed
    /// while the scanner was in `.metaBoot` mode (same UUID the board uses
    /// in application mode — CoreBluetooth keys peripherals by hardware
    /// MAC, not by advertised service set).
    ///
    /// Accepted file extensions: `.zip` (Nordic DFU distribution package),
    /// `.bin` / `.hex` (raw application image).
    public static func updateFirmware(
        identifier: UUID,
        zipURL: URL,
        fetcher: MWFirmwareFetcher = URLSessionFetcher()
    ) -> AsyncThrowingStream<DFUProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await _runExplicitURLFlash(
                        identifier: identifier,
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

    // MARK: - Update to catalog-latest

    /// Read the device's hardware revision and model number from its
    /// MetaBoot Device Information Service, look up the latest matching
    /// firmware on the MbientLab catalog, and flash it. Applies the same
    /// bootloader interlock the app-mode `updateFirmwareToLatest` uses —
    /// so an outdated bootloader auto-chains a bootloader-flavor stage
    /// before the application stage.
    ///
    /// Fails with `MWFirmwareError.noAvailableFirmware` if the board's
    /// (hardware, model) isn't recognised on the catalog. The MetaBoot
    /// probe timeout applies to the initial DIS read only (default 10 s).
    public static func updateFirmwareToLatest(
        identifier: UUID,
        server: MWFirmwareServer = MWFirmwareServer()
    ) -> AsyncThrowingStream<DFUProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await _runUpdateToLatest(
                        identifier: identifier,
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

    // MARK: - Drivers

    private static func _runExplicitURLFlash(
        identifier: UUID,
        zipURL: URL,
        fetcher: MWFirmwareFetcher,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        // Resolve the firmware URL to a local file.
        let localURL: URL
        if zipURL.isFileURL {
            localURL = zipURL
        } else {
            continuation.yield(DFUProgress(state: .downloadingFirmware))
            localURL = try await DFUFlasher.downloadToLocal(zipURL, fetcher: fetcher)
        }
        let firmware = try DFUFlasher.makeDFUFirmware(from: localURL)

        // Device is already in MetaBoot — go straight to the flash.
        // No interlock: an explicit-URL flash has no catalog metadata that
        // could describe a required bootloader.
        try await DFUFlasher.flashStages(
            [firmware],
            targetIdentifier: identifier,
            continuation: continuation
        )
    }

    private static func _runUpdateToLatest(
        identifier: UUID,
        server: MWFirmwareServer,
        continuation: AsyncThrowingStream<DFUProgress, Error>.Continuation
    ) async throws {
        // Step 1: read the DIS from MetaBoot. Hardware rev + model number
        // pick the catalog row; bootloader version feeds the interlock
        // without needing a second CB session later.
        continuation.yield(DFUProgress(state: .fetchingCatalog))
        let deviceInfo = try await MetaBootDeviceInfo.read(identifier: identifier)
        mwFirmwareLog(
            "[DFU] MetaBoot DIS: hw=\(deviceInfo.hardwareRevision) model=\(deviceInfo.modelNumber) bootloader=\(deviceInfo.bootloaderVersion)"
        )

        // Step 2: pick the latest firmware for this board on the catalog.
        // A MetaBoot device has no application firmware version to compare
        // against — always fetch the latest.
        let build = try await server.latestBuild(
            hardwareRev: deviceInfo.hardwareRevision,
            modelNumber: deviceInfo.modelNumber
        )
        mwFirmwareLog("[DFU] latest catalog build for hw=\(deviceInfo.hardwareRevision) model=\(deviceInfo.modelNumber): \(build.firmwareRev)")

        // Step 3: download the application image before doing anything
        // else, so a network failure bails out cleanly.
        continuation.yield(DFUProgress(state: .downloadingFirmware))
        let applicationURL = try await server.downloadFirmware(build)
        let application = try DFUFlasher.makeDFUFirmware(from: applicationURL)

        // Step 4: bootloader interlock. We already read the bootloader
        // version in step 1 — pass it in so the flasher doesn't spin up a
        // second CB probe session.
        var flashStages = try await DFUFlasher.bootloaderStagesIfNeeded(
            for: build,
            hardwareRev: deviceInfo.hardwareRevision,
            modelNumber: deviceInfo.modelNumber,
            server: server,
            targetIdentifier: identifier,
            installedBootloader: deviceInfo.bootloaderVersion,
            continuation: continuation
        )
        flashStages.append(application)

        // Step 5: flash. Device is already in MetaBoot mode, so we go
        // straight to Nordic without any handoff.
        try await DFUFlasher.flashStages(
            flashStages,
            targetIdentifier: identifier,
            continuation: continuation
        )
    }
}
