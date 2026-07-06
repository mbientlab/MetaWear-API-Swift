//
//  MACAdvertisementHardwareTests.swift
//  MetaWear
//
//  Hardware-required test for `MetaWearDevice.enableMACAdvertisement()`:
//  configures the board to broadcast its MAC in the scan response, then
//  verifies the claim over the air.
//
//  Out-of-the-box firmware (verified on 1.7.x) does NOT broadcast the MAC —
//  this feature is app-applied configuration. The test leaves the board with
//  NO persistent macro (macros are erased in cleanup); the live scan response
//  reverts to stock on the board's next power cycle.
//

import Testing
import MetaWear
import Foundation

@Suite("MAC advertisement", .serialized)
struct MACAdvertisementHardwareTests {

    // MARK: test_enable_mac_advertisement
    // enableMACAdvertisement records an on-boot macro AND applies the scan
    // response live. After disconnect, the very next advertisement cycle
    // must carry manufacturer data: company 0x626D + the MAC that the
    // settings register reported over the connection.

    @Test @MainActor
    func advertisementCarriesMACAfterConfiguration() async throws {
        var identifier: UUID?
        var connectedMAC: String?
        var advertisedName: String?

        try await withConnectedDevice { device in
            identifier = device.identifier
            connectedMAC = try await device.read(MWSettings.ReadMacAddress()).value

            // Erase macros FIRST so the macro this test records is the only
            // one, and the board is left clean afterwards.
            try await resetBoardState(device)

            let macro = try await device.enableMACAdvertisement()
            print("  Recorded on-boot macro id \(macro.id) for MAC \(connectedMAC ?? "?")")

            // Clean up the persistent half immediately — the live scan
            // response survives until reboot, which is all the air check
            // needs, and the board isn't left permanently modified by a test.
            try await device.eraseAllMacros()
        }

        let id = try #require(identifier)
        let expectedMAC = try #require(connectedMAC)

        // The board re-advertises after disconnect; its scan response must
        // now carry the MbientLab manufacturer structure.
        let manufacturerData = try #require(
            try await awaitManufacturerData(for: id, timeout: .seconds(10)),
            "No manufacturer data observed after configuration"
        )
        let advertisedMAC = try #require(
            MWMACAdvertisement.mac(fromManufacturerData: manufacturerData),
            "Manufacturer data present but not parseable as a MbientLab MAC: \(Array(manufacturerData))"
        )
        #expect(advertisedMAC == expectedMAC)

        // The name AD embedded alongside the MAC must keep the board
        // discoverable — the scanner filters on the "MetaWear" prefix.
        advertisedName = try await awaitAdvertisedName(for: id, timeout: .seconds(5))
        #expect(advertisedName?.hasPrefix("MetaWear") == true,
                "Name lost from scan response: \(advertisedName ?? "nil")")
    }
}
