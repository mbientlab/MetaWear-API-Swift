//
//  BootloaderInterlock.swift
//  MetaWearFirmware
//
//  Decides whether a firmware flash must be preceded by bootloader flashes.
//
//  Every catalog build declares the minimum bootloader it needs
//  (`required-bootloader` -> `MWFirmwareBuild.requiredBootloader`). Flashing
//  an application image onto a board whose bootloader is older fails inside
//  Nordic DFU validation and leaves the board sitting in MetaBoot — so the
//  orchestrator reads the on-board bootloader version (MetaBoot's Device
//  Information service) and consults this pure decision table first.
//
//  Bootloader builds carry `required-bootloader` themselves, so one upgrade
//  may need stepping stones: the plan is a CHAIN of bootloader flashes, each
//  flashable from the version the previous one leaves behind.
//
//  Kept free of device/network dependencies so the outcomes are directly
//  unit-testable.
//

import Foundation

enum BootloaderInterlock {

    enum Plan: Equatable {
        /// The installed bootloader satisfies the target build — flash the
        /// application image directly.
        case flashApplicationOnly
        /// The installed bootloader is too old — flash these bootloader
        /// builds in order (oldest hop first), then the application image.
        case flashBootloadersFirst([MWFirmwareBuild])
    }

    /// Decide the flash plan for a target build.
    ///
    /// When an upgrade is needed, greedily picks the newest catalog
    /// bootloader that is flashable from the currently installed version,
    /// repeating until the requirement is met — each hop strictly increases
    /// the version, so the walk terminates.
    ///
    /// - Parameters:
    ///   - installedBootloader: Version read from MetaBoot's Firmware Revision
    ///     characteristic (e.g. `"0.4.0"`).
    ///   - requiredBootloader: The target build's requirement; `nil` means the
    ///     build declares none and the application flashes directly.
    ///   - availableBootloaders: Catalog builds of the `"bootloader"` flavor
    ///     for this (hardwareRev, modelNumber), ascending by version — the
    ///     order `MWFirmwareServer.availableBuilds` returns.
    ///   - hardwareRev: For the error, so the user-facing message names the
    ///     hardware whose catalog is missing the bootloader.
    /// - Throws: `MWFirmwareError.bootloaderUpgradeUnavailable` when an
    ///   upgrade is needed but no reachable chain of catalog bootloaders
    ///   satisfies the requirement — flashing the application anyway would
    ///   strand the board in MetaBoot.
    static func plan(
        installedBootloader: String,
        requiredBootloader: String?,
        availableBootloaders: [MWFirmwareBuild],
        hardwareRev: String
    ) throws -> Plan {
        guard let requiredBootloader,
              installedBootloader.isMetaWearVersion(lessThan: requiredBootloader) else {
            return .flashApplicationOnly
        }
        var chain: [MWFirmwareBuild] = []
        var current = installedBootloader
        while current.isMetaWearVersion(lessThan: requiredBootloader) {
            // Ascending input + order-preserving filter: `.last` is the
            // newest hop flashable from where the chain currently stands.
            guard let next = availableBootloaders.last(where: { build in
                build.firmwareRev.isMetaWearVersion(greaterThan: current)
                    && isFlashable(build, from: current)
            }) else {
                throw MWFirmwareError.bootloaderUpgradeUnavailable(
                    requiredVersion: requiredBootloader,
                    hardwareRev: hardwareRev
                )
            }
            chain.append(next)
            current = next.firmwareRev
        }
        return .flashBootloadersFirst(chain)
    }

    /// Whether `build` can be flashed onto a board whose bootloader is
    /// currently `installed`.
    ///
    /// No declared requirement means always flashable. A SELF-referential
    /// requirement (the live catalog lists bootloader 0.4.0 as requiring
    /// 0.4.0) is metadata noise, not a real gate — taken literally it would
    /// make the build unflashable from every older bootloader, i.e. useless
    /// for the only purpose a bootloader build has.
    private static func isFlashable(_ build: MWFirmwareBuild, from installed: String) -> Bool {
        guard let required = build.requiredBootloader else { return true }
        if required.isMetaWearVersion(equalTo: build.firmwareRev) { return true }
        return installed.isMetaWearVersion(greaterThanOrEqualTo: required)
    }
}
