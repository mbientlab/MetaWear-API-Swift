//
//  MWFirmwareError.swift
//  MetaWearFirmware
//
//  Error taxonomy for the firmware-update pipeline. Covers three layers:
//    • catalog/network    — HTTP fetch failures, malformed JSON, no matching build
//    • orchestration      — bootloader handoff, rediscovery, state-machine misuse
//    • DFU transfer       — errors propagated from the Nordic DFU library
//

import Foundation

public enum MWFirmwareError: Error, Sendable, Equatable {

    // MARK: - Catalog / network

    /// Catalog server returned a non-2xx HTTP status.
    case badServerResponse(status: Int)

    /// JSON returned by the catalog server didn't deserialize into the
    /// expected `[hwRev: [model: [flavor: [version: {…}]]]]` shape.
    case invalidServerResponse(message: String)

    /// No firmware on the catalog matches this device + this SDK version.
    /// The associated message identifies the (hardwareRev, modelNumber,
    /// buildFlavor) tuple that came back empty.
    case noAvailableFirmware(message: String)

    /// Could not write the downloaded firmware to a temporary file.
    case cannotSaveFile(message: String)

    /// The downloaded file isn't a recognised firmware container — extension
    /// must be `.zip` (preferred — Nordic DFU distribution package) or
    /// `.bin` / `.hex` (raw application binary, no init packet).
    case invalidFirmwareFile(URL)

    // MARK: - Bootloader interlock

    /// The new firmware requires a specific bootloader version that isn't
    /// available on the catalog, so the upgrade can't proceed.
    case bootloaderUpgradeUnavailable(requiredVersion: String, hardwareRev: String)

    /// `updateFirmware(_:)` was called but the device isn't in a state where
    /// the bootloader handoff (`[0xFE, 0x02]`) is safe — typically because
    /// the device is mid-stream / mid-log / mid-download.
    case deviceNotIdle

    // MARK: - DFU

    /// The Nordic DFU library reported an error during transfer. The
    /// associated message is the library's own error description, which
    /// distinguishes transport drops, CRC mismatches, signature failures,
    /// and "device disconnected unexpectedly" cases. Propagated verbatim
    /// because the library's enum isn't `Sendable` / `Equatable`.
    case dfuFailed(message: String)

    /// DFU was aborted by the caller (cancelling the iteration of the
    /// returned `AsyncThrowingStream`).
    case aborted

    // MARK: - Catch-all

    /// Anything else (transport errors during handoff, scanner timeouts
    /// while waiting for MetaBoot rediscovery, etc.).
    case operationFailed(String)
}

extension MWFirmwareError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badServerResponse(let status):
            return "Firmware catalog server returned HTTP \(status)."
        case .invalidServerResponse(let message):
            return "Invalid firmware catalog response: \(message)"
        case .noAvailableFirmware(let message):
            return "No firmware available: \(message)"
        case .cannotSaveFile(let message):
            return "Cannot save firmware file: \(message)"
        case .invalidFirmwareFile(let url):
            return "Unrecognised firmware file '\(url.lastPathComponent)' — expected .zip, .bin, or .hex."
        case .bootloaderUpgradeUnavailable(let required, let hwRev):
            return "Firmware update needs bootloader \(required) for hardware \(hwRev), but it isn't on the catalog."
        case .deviceNotIdle:
            return "Cannot update firmware while the device is streaming, logging, or downloading."
        case .dfuFailed(let message):
            return "DFU failed: \(message)"
        case .aborted:
            return "Firmware update was aborted."
        case .operationFailed(let message):
            return message
        }
    }
}
