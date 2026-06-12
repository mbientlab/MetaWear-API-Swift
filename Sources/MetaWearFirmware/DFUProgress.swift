//
//  DFUProgress.swift
//  MetaWearFirmware
//
//  Public progress event yielded by the AsyncThrowingStream returned from
//  `MetaWearDevice.updateFirmware(...)`.
//

import Foundation

/// One snapshot of firmware-update progress.
///
/// The state machine moves forward through the phases below; `percentComplete`
/// is meaningful only during `.uploading`. Other phases yield with
/// `percentComplete == 0`.
public struct DFUProgress: Sendable, Equatable {

    public enum State: Sendable, Equatable {
        /// Looking up the firmware build (catalog fetch + version selection).
        /// Skipped when the caller supplies an explicit zip URL.
        case fetchingCatalog

        /// Downloading the firmware file from MbientLab's CDN to a temporary
        /// location. Skipped for `file://` URLs.
        case downloadingFirmware

        /// Sending `[0xFE, 0x02]` to the device, then waiting for the BLE
        /// link to drop.
        case bootloaderHandoff

        /// Disconnected from app-mode peripheral; Nordic DFU is now scanning
        /// for the bootloader-mode peripheral (same UUID, different services).
        case scanning

        /// Connecting to the bootloader-mode peripheral.
        case connecting

        /// DFU service set up; sending the init packet and SELECT command.
        case starting

        /// Validating the firmware image type / device-type match.
        case validating

        /// Actively transferring firmware bytes. `percentComplete` is the
        /// signal to drive a UI progress bar.
        case uploading

        /// Transfer finished, board is rebooting back into application mode.
        case disconnecting

        /// All done — board is back in app mode with new firmware.
        case completed

        /// Caller cancelled iteration of the stream, or the orchestrator
        /// caught a fatal error mid-flight.
        case aborted
    }

    /// Current phase of the update.
    public let state: State

    /// 0…100. Only populated during `.uploading`; other phases report 0.
    public let percentComplete: Double

    /// Which sub-image of a multi-part DFU is currently uploading. Most
    /// MetaWear firmware ships as a single application image, so this is
    /// usually `1`.
    public let currentPart: Int

    /// Total parts in the DFU package. Usually `1` (application only); rises
    /// to `2` when a softdevice or bootloader image is also present.
    public let totalParts: Int

    /// Instantaneous transfer rate during `.uploading`, in bytes/sec.
    /// 0 outside the upload phase.
    public let bytesPerSecond: Double

    public init(
        state: State,
        percentComplete: Double = 0,
        currentPart: Int = 1,
        totalParts: Int = 1,
        bytesPerSecond: Double = 0
    ) {
        self.state = state
        self.percentComplete = percentComplete
        self.currentPart = currentPart
        self.totalParts = totalParts
        self.bytesPerSecond = bytesPerSecond
    }
}
