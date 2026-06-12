import Testing
import Foundation
import MetaWear

@Suite("Hardware — iBeacon", .serialized)
struct iBeaconTests {

    @Test @MainActor
    func iBeacon_enableAndDisable_doesNotThrow() async throws {
        // The test writes an iBeacon configuration, enables advertising,
        // disconnects so the board can actually go on-air, then rescans and
        // verifies the manufacturer-specific advertisement payload matches the
        // Apple iBeacon format with the UUID/major/minor we just wrote. Finally
        // it reconnects, disables iBeacon mode, disconnects again, and rescans
        // to confirm the board is back to regular MetaWear advertising.
        //
        // NOTE: CoreBluetooth filters iBeacon advertisements from foreground
        // scans on some iOS versions. When we can't observe the payload the
        // test records a soft skip rather than failing — the write path is
        // still proven by the commands succeeding end-to-end.

        let device = try await nearbyDevice()
        let uuid = device.identifier

        // Probe module presence on a short-lived connection.
        try await device.connect()
        guard await device.moduleInfo(for: .iBeacon)?.isPresent == true else {
            try await device.disconnect()
            print("\n  Skipping iBeacon — module not present\n")
            return
        }

        // --- Configure iBeacon parameters -----------------------------------
        let beaconUUID = UUID()
        let major: UInt16 = 0xBEEF
        let minor: UInt16 = 0x1234
        let measuredRSSI: Int8 = -55

        try await device.send(MWiBeacon.SetUUID(uuid: beaconUUID))
        try await device.send(MWiBeacon.SetMajor(major))
        try await device.send(MWiBeacon.SetMinor(minor))
        try await device.send(MWiBeacon.SetRXPower(measuredRSSI))
        try await device.send(MWiBeacon.SetTXPower(-4))
        try await device.send(MWiBeacon.SetPeriod(700))
        try await device.send(MWiBeacon.Enable())

        // The board stops advertising while a central is connected. Disconnect
        // so it goes back on air in iBeacon mode.
        try await Task.sleep(for: .seconds(3))
        try await device.disconnect()
        try await Task.sleep(for: .seconds(3))

        // --- Verify the iBeacon payload is on the air -----------------------
        print("\n  Expected iBeacon UUID:  \(beaconUUID)")
        print("  Expected major / minor: 0x\(String(major, radix: 16).uppercased()) / 0x\(String(minor, radix: 16).uppercased())")

        let ibeaconPayload = try await awaitManufacturerData(for: uuid, timeout: .seconds(8))
        if let data = ibeaconPayload, let parsed = parseIBeacon(data) {
            print("  Observed iBeacon UUID:  \(parsed.uuid)")
            print("  Observed major / minor: 0x\(String(parsed.major, radix: 16).uppercased()) / 0x\(String(parsed.minor, radix: 16).uppercased())")
            print("  Measured power:         \(parsed.measuredPower) dBm\n")

            #expect(parsed.uuid == beaconUUID,
                    "iBeacon UUID on air (\(parsed.uuid)) does not match written value (\(beaconUUID))")
            #expect(parsed.major == major,
                    "iBeacon major on air (\(parsed.major)) does not match written value (\(major))")
            #expect(parsed.minor == minor,
                    "iBeacon minor on air (\(parsed.minor)) does not match written value (\(minor))")
            #expect(parsed.measuredPower == measuredRSSI,
                    "iBeacon measured RSSI on air (\(parsed.measuredPower)) does not match written value (\(measuredRSSI))")
        } else {
            // macOS normally delivers the bytes; iOS sometimes filters iBeacon
            // advertisements from foreground scans. Record as a soft miss.
            print("  ⚠ No iBeacon manufacturer-data observed — platform may be filtering Apple beacons\n")
            Issue.record("Expected an iBeacon manufacturer-data payload after Enable() — none observed within 8 s (platform may filter iBeacon advertisements)")
        }

        // --- Disable iBeacon and restore regular MetaWear advertising -------
        try await device.connect()
        try await device.send(MWiBeacon.Disable())
        try await Task.sleep(for: .seconds(3))
        try await device.disconnect()
        try await Task.sleep(for: .seconds(3))

        let afterDisable = try await awaitManufacturerData(for: uuid, timeout: .seconds(5))
        if let data = afterDisable, let stillBeacon = parseIBeacon(data) {
            Issue.record("Expected no iBeacon payload after Disable(), but still observed UUID \(stillBeacon.uuid)")
        } else {
            print("  ✓ iBeacon payload cleared after Disable() — device back to regular advertising\n")
        }

        // Sanity-check that the board is advertising its MetaWear name again.
        if let name = try await awaitAdvertisedName(for: uuid, timeout: .seconds(5)) {
            print("  Advertised name after disable: \"\(name)\"\n")
            #expect(name.hasPrefix("MetaWear"),
                    "Expected MetaWear-prefixed advertised name after disabling iBeacon, got \"\(name)\"")
        }
    }
}
