//
//  BootloaderInterlockTests.swift
//  MetaWearFirmwareTests
//
//  Coverage for the pure decision table behind the bootloader interlock:
//  flash the application directly, stage a bootloader flash first, or refuse
//  because the catalog can't satisfy the requirement.
//

import Foundation
import Testing
@testable import MetaWearFirmware

@Suite("Bootloader interlock")
struct BootloaderInterlockTests {

    private func bootloaderBuild(
        _ version: String,
        requires: String? = nil
    ) -> MWFirmwareBuild {
        MWFirmwareBuild(
            hardwareRev: "0.1",
            modelNumber: "8",
            buildFlavor: "bootloader",
            firmwareRev: version,
            filename: "temp.zip",
            requiredBootloader: requires
        )
    }

    @Test
    func upToDateBootloaderFlashesApplicationOnly() throws {
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.4.0",
            requiredBootloader: "0.4.0",
            availableBootloaders: [bootloaderBuild("0.4.0")],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashApplicationOnly)
    }

    @Test
    func newerThanRequiredFlashesApplicationOnly() throws {
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.5.1",
            requiredBootloader: "0.4.0",
            availableBootloaders: [bootloaderBuild("0.4.0")],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashApplicationOnly)
    }

    @Test
    func noRequirementFlashesApplicationOnly() throws {
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.1.0",
            requiredBootloader: nil,
            availableBootloaders: [],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashApplicationOnly)
    }

    @Test
    func outdatedBootloaderStagesUpgradeFirst() throws {
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.3.2",
            requiredBootloader: "0.4.0",
            availableBootloaders: [bootloaderBuild("0.3.0"), bootloaderBuild("0.4.0")],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashBootloadersFirst([bootloaderBuild("0.4.0")]))
    }

    @Test
    func picksNewestSatisfyingBootloader() throws {
        // Ascending catalog order; the newest flashable build wins, not the
        // minimum one — a single hop when nothing gates it.
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.2.0",
            requiredBootloader: "0.4.0",
            availableBootloaders: [
                bootloaderBuild("0.3.0"),
                bootloaderBuild("0.4.0"),
                bootloaderBuild("0.5.0"),
            ],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashBootloadersFirst([bootloaderBuild("0.5.0")]))
    }

    @Test
    func selfReferentialRequirementIsFlashable() throws {
        // The live catalog lists bootloader 0.4.0 as requiring 0.4.0 —
        // metadata noise, not a gate; taking it literally would make the
        // build unflashable from every older bootloader.
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.3.0",
            requiredBootloader: "0.4.0",
            availableBootloaders: [bootloaderBuild("0.4.0", requires: "0.4.0")],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashBootloadersFirst([bootloaderBuild("0.4.0", requires: "0.4.0")]))
    }

    @Test
    func chainsThroughIntermediateBootloader() throws {
        // 0.5 can't flash from 0.2 (it requires 0.3), so the plan steps
        // through 0.3 first: two hops, oldest first.
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.2.0",
            requiredBootloader: "0.5.0",
            availableBootloaders: [
                bootloaderBuild("0.3.0"),
                bootloaderBuild("0.5.0", requires: "0.3.0"),
            ],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashBootloadersFirst([
            bootloaderBuild("0.3.0"),
            bootloaderBuild("0.5.0", requires: "0.3.0"),
        ]))
    }

    @Test
    func unreachableChainThrows() throws {
        // The only adequate bootloader needs a stepping stone the catalog
        // doesn't carry — refusing beats stranding the board mid-flash.
        #expect(throws: MWFirmwareError.bootloaderUpgradeUnavailable(
            requiredVersion: "0.5.0", hardwareRev: "0.1"
        )) {
            _ = try BootloaderInterlock.plan(
                installedBootloader: "0.2.0",
                requiredBootloader: "0.5.0",
                availableBootloaders: [bootloaderBuild("0.5.0", requires: "0.3.0")],
                hardwareRev: "0.1"
            )
        }
    }

    @Test
    func missingCatalogBootloaderThrows() throws {
        #expect(throws: MWFirmwareError.bootloaderUpgradeUnavailable(
            requiredVersion: "0.4.0", hardwareRev: "0.1"
        )) {
            _ = try BootloaderInterlock.plan(
                installedBootloader: "0.3.2",
                requiredBootloader: "0.4.0",
                availableBootloaders: [bootloaderBuild("0.3.0")],
                hardwareRev: "0.1"
            )
        }
    }

    @Test
    func emptyCatalogThrowsWhenUpgradeNeeded() throws {
        #expect(throws: MWFirmwareError.bootloaderUpgradeUnavailable(
            requiredVersion: "0.4.0", hardwareRev: "0.1"
        )) {
            _ = try BootloaderInterlock.plan(
                installedBootloader: "0.2.0",
                requiredBootloader: "0.4.0",
                availableBootloaders: [],
                hardwareRev: "0.1"
            )
        }
    }

    @Test
    func versionComparisonIsNumericNotLexicographic() throws {
        // "0.10" must sort ABOVE "0.9" — a lexicographic comparison would
        // wrongly stage an upgrade here.
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.10",
            requiredBootloader: "0.9",
            availableBootloaders: [bootloaderBuild("0.9")],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashApplicationOnly)
    }

    @Test
    func paddedVersionsCompareEqual() throws {
        // "0.4" and "0.4.0" are the same version in MetaWear's loose form.
        let plan = try BootloaderInterlock.plan(
            installedBootloader: "0.4",
            requiredBootloader: "0.4.0",
            availableBootloaders: [],
            hardwareRev: "0.1"
        )
        #expect(plan == .flashApplicationOnly)
    }
}
