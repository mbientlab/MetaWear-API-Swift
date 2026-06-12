//
//  MWFirmwareBuild.swift
//  MetaWearFirmware
//
//  Value type describing one firmware artifact on MbientLab's release CDN.
//

import Foundation

/// One firmware build: which board variant + flavor + version, plus the
/// catalog metadata needed to fetch + validate it.
public struct MWFirmwareBuild: Sendable, Equatable {

    /// Hardware revision string the board reports via the standard BLE Device
    /// Information service (e.g. `"0.4"`). Used as the first key in the
    /// catalog JSON.
    public let hardwareRev: String

    /// Model number string the board reports (e.g. `"5"` for MetaMotion R,
    /// `"6"` for MetaMotion C, `"8"` for MetaMotion S). Second catalog key.
    public let modelNumber: String

    /// Firmware variant — `"vanilla"` is the standard release; MbientLab also
    /// publishes `"bootloader"` builds (used internally for bootloader
    /// upgrades) and occasional custom flavors. Third catalog key.
    public let buildFlavor: String

    /// Firmware version this build represents (e.g. `"1.7.3"`).
    public let firmwareRev: String

    /// Filename on the CDN (typically `"firmware.zip"` for newer Nordic-
    /// signed packages, `"firmware.bin"` for older raw application binaries).
    public let filename: String

    /// If non-nil, the bootloader version that must already be running on
    /// the device for this firmware to flash successfully. If the device's
    /// bootloader is older, the orchestrator must DFU the bootloader first.
    public let requiredBootloader: String?

    /// HTTP URL to download the firmware file from MbientLab's CDN.
    /// Composed from the four catalog keys plus the filename:
    /// ```
    /// https://mbientlab.com/releases/metawear/<hwRev>/<model>/<flavor>/<fwRev>/<filename>
    /// ```
    public let firmwareURL: URL

    public init(
        hardwareRev: String,
        modelNumber: String,
        buildFlavor: String,
        firmwareRev: String,
        filename: String,
        requiredBootloader: String?
    ) {
        self.hardwareRev = hardwareRev
        self.modelNumber = modelNumber
        self.buildFlavor = buildFlavor
        self.firmwareRev = firmwareRev
        self.filename = filename
        self.requiredBootloader = requiredBootloader
        // Force-unwrap is safe because the input strings come from the
        // catalog JSON or hand-constructed test values — they don't contain
        // path-illegal characters under normal use. Use the `customURL`
        // initializer below for off-CDN builds.
        self.firmwareURL = URL(
            string: "https://mbientlab.com/releases/metawear/\(hardwareRev)/\(modelNumber)/\(buildFlavor)/\(firmwareRev)/\(filename)"
        )!
    }

    /// Construct a build pointing at a custom firmware URL (file:// for a
    /// local zip, or a non-MbientLab CDN). Used when the caller has already
    /// fetched a firmware file by other means and wants to feed it through
    /// the same DFU orchestration as a CDN-sourced build.
    public init(
        hardwareRev: String,
        modelNumber: String,
        firmwareRev: String,
        customURL: URL,
        filename: String? = nil,
        buildFlavor: String = "vanilla",
        requiredBootloader: String? = nil
    ) {
        self.hardwareRev = hardwareRev
        self.modelNumber = modelNumber
        self.buildFlavor = buildFlavor
        self.firmwareRev = firmwareRev
        self.filename = filename ?? customURL.lastPathComponent
        self.requiredBootloader = requiredBootloader
        self.firmwareURL = customURL
    }
}
