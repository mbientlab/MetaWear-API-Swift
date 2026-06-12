//
//  MWFirmwareErrorTests.swift
//  MetaWearFirmwareTests
//
//  Smoke coverage for `MWFirmwareError` — the values are simple but the
//  `LocalizedError` strings ship in user-facing UI, so it's worth catching
//  copy regressions.
//

import Foundation
import Testing
@testable import MetaWearFirmware

@Suite("MWFirmwareError")
struct MWFirmwareErrorTests {

    // MARK: - errorDescription content (smoke)

    @Test
    func descriptions_includeVariantDetails() {
        #expect(MWFirmwareError.badServerResponse(status: 500)
                .errorDescription?.contains("500") == true)
        #expect(MWFirmwareError.invalidServerResponse(message: "shape mismatch")
                .errorDescription?.contains("shape mismatch") == true)
        #expect(MWFirmwareError.noAvailableFirmware(message: "no MMR builds")
                .errorDescription?.contains("no MMR builds") == true)
        #expect(MWFirmwareError.cannotSaveFile(message: "disk full")
                .errorDescription?.contains("disk full") == true)
        let url = URL(fileURLWithPath: "/tmp/oddball.tar")
        #expect(MWFirmwareError.invalidFirmwareFile(url)
                .errorDescription?.contains("oddball.tar") == true)
        #expect(MWFirmwareError.bootloaderUpgradeUnavailable(requiredVersion: "0.5", hardwareRev: "0.4")
                .errorDescription?.contains("0.5") == true)
        #expect(MWFirmwareError.deviceNotIdle
                .errorDescription?.contains("streaming") == true)
        #expect(MWFirmwareError.dfuFailed(message: "CRC mismatch")
                .errorDescription?.contains("CRC mismatch") == true)
        #expect(MWFirmwareError.aborted
                .errorDescription?.contains("aborted") == true)
        #expect(MWFirmwareError.operationFailed("unexpected drop")
                .errorDescription?.contains("unexpected drop") == true)
    }

    // MARK: - Equatable

    @Test
    func errors_equalWhenSameVariantAndPayload() {
        #expect(MWFirmwareError.badServerResponse(status: 404)
                == MWFirmwareError.badServerResponse(status: 404))
        #expect(MWFirmwareError.aborted == MWFirmwareError.aborted)
    }

    @Test
    func errors_differOnPayload() {
        #expect(MWFirmwareError.badServerResponse(status: 404)
                != MWFirmwareError.badServerResponse(status: 500))
        #expect(MWFirmwareError.dfuFailed(message: "a")
                != MWFirmwareError.dfuFailed(message: "b"))
    }
}
