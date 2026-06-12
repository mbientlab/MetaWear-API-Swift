//
//  MWFirmwareBuildTests.swift
//  MetaWearFirmwareTests
//
//  Coverage for `MWFirmwareBuild` URL composition and equality. The catalog-
//  initializer composes a CDN URL from the four catalog keys + filename;
//  the custom-URL initializer accepts an off-CDN URL as-is.
//

import Foundation
import Testing
@testable import MetaWearFirmware

@Suite("MWFirmwareBuild")
struct MWFirmwareBuildTests {

    // MARK: - CDN URL composition

    @Test
    func cdnURL_composedFromCatalogKeys() {
        let build = MWFirmwareBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            firmwareRev: "1.7.3",
            filename: "firmware.zip",
            requiredBootloader: "0.5"
        )
        #expect(build.firmwareURL.absoluteString ==
                "https://mbientlab.com/releases/metawear/0.4/5/vanilla/1.7.3/firmware.zip")
    }

    @Test
    func cdnURL_handlesAllStandardModelNumbers() {
        // MetaMotion R = 5, C = 6, S = 8 in MbientLab's catalog
        for model in ["5", "6", "8"] {
            let build = MWFirmwareBuild(
                hardwareRev: "0.4",
                modelNumber: model,
                buildFlavor: "vanilla",
                firmwareRev: "1.7.3",
                filename: "firmware.zip",
                requiredBootloader: nil
            )
            let suffix = "/metawear/0.4/\(model)/vanilla/1.7.3/firmware.zip"
            #expect(build.firmwareURL.absoluteString.hasSuffix(suffix))
        }
    }

    @Test
    func cdnURL_handlesAllStandardFlavors() {
        for flavor in ["vanilla", "bootloader"] {
            let build = MWFirmwareBuild(
                hardwareRev: "0.4",
                modelNumber: "5",
                buildFlavor: flavor,
                firmwareRev: "1.7.3",
                filename: "firmware.zip",
                requiredBootloader: nil
            )
            #expect(build.firmwareURL.absoluteString.contains("/\(flavor)/"))
        }
    }

    // MARK: - Custom URL initializer

    @Test
    func customURL_usedAsIs() {
        let url = URL(string: "https://example.com/test/firmware.zip")!
        let build = MWFirmwareBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            firmwareRev: "1.7.3",
            customURL: url
        )
        #expect(build.firmwareURL == url)
        #expect(build.buildFlavor == "vanilla")          // default
        #expect(build.filename == "firmware.zip")        // derived from URL
        #expect(build.requiredBootloader == nil)
    }

    @Test
    func customURL_acceptsFileURL() {
        let fileURL = URL(fileURLWithPath: "/tmp/firmware.zip")
        let build = MWFirmwareBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            firmwareRev: "1.7.3",
            customURL: fileURL
        )
        #expect(build.firmwareURL.isFileURL)
        #expect(build.filename == "firmware.zip")
    }

    @Test
    func customURL_overrideFilenameAndFlavor() {
        let url = URL(string: "https://example.com/anything")!
        let build = MWFirmwareBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            firmwareRev: "0.4.0",
            customURL: url,
            filename: "bootloader.zip",
            buildFlavor: "bootloader",
            requiredBootloader: nil
        )
        #expect(build.filename == "bootloader.zip")
        #expect(build.buildFlavor == "bootloader")
    }

    // MARK: - Equatable

    @Test
    func builds_equalWhenAllFieldsMatch() {
        let a = MWFirmwareBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            firmwareRev: "1.7.3",
            filename: "firmware.zip",
            requiredBootloader: "0.5"
        )
        let b = MWFirmwareBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            firmwareRev: "1.7.3",
            filename: "firmware.zip",
            requiredBootloader: "0.5"
        )
        #expect(a == b)
    }

    @Test
    func builds_differOnAnyField() {
        let base = MWFirmwareBuild(
            hardwareRev: "0.4", modelNumber: "5", buildFlavor: "vanilla",
            firmwareRev: "1.7.3", filename: "firmware.zip",
            requiredBootloader: "0.5"
        )
        let differentRev = MWFirmwareBuild(
            hardwareRev: "0.4", modelNumber: "5", buildFlavor: "vanilla",
            firmwareRev: "1.8.0", filename: "firmware.zip",
            requiredBootloader: "0.5"
        )
        #expect(base != differentRev)
    }
}
