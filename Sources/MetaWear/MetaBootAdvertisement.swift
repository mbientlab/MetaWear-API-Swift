//
//  MetaBootAdvertisement.swift
//  MetaWear
//
//  Lightweight descriptor for a MetaWear that has been observed advertising
//  in MetaBoot (bootloader) mode.
//
//  In MetaBoot mode the board doesn't expose the MetaWear command service,
//  so there's no `MetaWearDevice` to hand out — the normal connect/read/
//  write pipeline can't talk to it. What the app *can* do is:
//     • identify it (name + UUID + last seen);
//     • connect briefly via CoreBluetooth to read the Device Information
//       Service (`MetaBootDeviceInfo.read(identifier:)` in the
//       `MetaWearFirmware` module);
//     • hand the same UUID to the Nordic DFU library to flash firmware.
//
//  This descriptor is populated by `MetaWearScanner` while
//  `scanMode == .metaBoot`. It carries only what's meaningful without a
//  MetaWear command channel — richer facts (bootloader version, hardware
//  revision, model number) come from the DIS read in `MetaWearFirmware`.
//

import Foundation

public struct MetaBootAdvertisement: Sendable, Equatable, Hashable, Identifiable {

    /// CoreBluetooth peripheral UUID — same identity the board uses in
    /// application mode (CoreBluetooth keys peripherals by hardware MAC,
    /// not by advertised service set).
    public let identifier: UUID

    /// Advertised local name. Almost always the literal string
    /// `"MetaBoot"`; kept as a stored property so the caller UI has a
    /// human-readable label even for rare boards that customise the
    /// bootloader name.
    public let name: String

    public var id: UUID { identifier }

    public init(identifier: UUID, name: String = "MetaBoot") {
        self.identifier = identifier
        self.name = name
    }
}
