//
//  MWMACAdvertisement.swift
//  MetaWear
//
//  Builds and parses the MetaWear MAC-broadcast scan response.
//
//  iOS/macOS hide the true Bluetooth address of peripherals, so two Apple
//  devices cannot recognize the same physical board by CoreBluetooth
//  identifier — those are generated independently per host. The board itself
//  can bridge that gap: its scan response can carry a manufacturer-specific
//  AD structure (MbientLab company identifier 0x626D) containing the 6-byte
//  MAC. `MetaWearDevice.enableMACAdvertisement()` programs it persistently
//  (on-boot macro + immediate apply), and `MetaWearScanner.advertisedMACs`
//  surfaces the parsed values during scanning.
//
//  Out-of-the-box firmware does NOT broadcast the MAC (verified on fw 1.7.x
//  over the air) — the capability exists but the default scan response
//  doesn't use it, which is why this is an app-applied configuration.
//

import Foundation

public enum MWMACAdvertisement {

    /// MbientLab's Bluetooth SIG company identifier (0x626D — "mb" in ASCII),
    /// transmitted little-endian on air.
    public static let companyIdentifier: UInt16 = 0x626D

    // MARK: - Payload assembly

    /// Assemble a scan-response payload: a Complete Local Name AD structure
    /// (so the advertised name survives replacing the default scan response)
    /// followed by a manufacturer-data AD structure carrying the company ID
    /// and the 6 MAC bytes LSB-first — the same byte order as every other
    /// MAC transport in the MetaWear protocol.
    ///
    /// Layout for name "MetaWear", MAC ED:AA:A4:CE:A6:A4 (20 of 31 bytes):
    /// ```
    /// 09 09 4D 65 74 61 57 65 61 72   len=9 type=CompleteLocalName "MetaWear"
    /// 09 FF 6D 62 A4 A6 CE A4 AA ED   len=9 type=ManufacturerData 0x626D + MAC
    /// ```
    ///
    /// - Parameters:
    ///   - name: Advertised device name. Clamped to 19 UTF-8 bytes so the
    ///     payload fits the 31-byte scan response alongside the 10-byte
    ///     manufacturer structure. An empty name omits the name structure.
    ///   - mac: Display form, e.g. `"ED:AA:A4:CE:A6:A4"`.
    public static func scanResponsePayload(name: String, mac: String) throws -> [UInt8] {
        let displayBytes = try macBytes(fromDisplay: mac)
        let nameBytes = Array(name.utf8.prefix(19))
        var payload: [UInt8] = []
        if !nameBytes.isEmpty {
            payload += [UInt8(nameBytes.count + 1), 0x09] + nameBytes
        }
        payload += [0x09, 0xFF,
                    UInt8(companyIdentifier & 0xFF),
                    UInt8(companyIdentifier >> 8)]
        payload += displayBytes.reversed()
        return payload
    }

    // MARK: - Parsing

    /// Extract a MAC address from `CBAdvertisementDataManufacturerDataKey`
    /// bytes. CoreBluetooth strips the AD structure header, so the data
    /// begins at the (little-endian) company identifier. Returns `nil` for
    /// non-MbientLab payloads — e.g. the Apple company ID a board broadcasts
    /// in iBeacon mode — or truncated data.
    public static func mac(fromManufacturerData data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              bytes[0] == UInt8(companyIdentifier & 0xFF),
              bytes[1] == UInt8(companyIdentifier >> 8) else { return nil }
        return bytes[2..<8].reversed()
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    // MARK: - Internal

    /// Parse a display-form MAC ("ED:AA:A4:CE:A6:A4") into its 6 bytes,
    /// most-significant first.
    static func macBytes(fromDisplay display: String) throws -> [UInt8] {
        let parts = display.split(separator: ":")
        guard parts.count == 6 else {
            throw MWError.operationFailed("Invalid MAC address: \(display)")
        }
        return try parts.map {
            guard $0.count == 2, let byte = UInt8($0, radix: 16) else {
                throw MWError.operationFailed("Invalid MAC address: \(display)")
            }
            return byte
        }
    }
}

// MARK: - Device convenience

public extension MetaWearDevice {

    /// Make the board broadcast its MAC address in its scan response —
    /// persistently — so any Apple device can recognize it during scanning,
    /// before ever connecting.
    ///
    /// Records an on-boot macro (macros survive resets and power cycles) and
    /// ALSO applies the scan response immediately: macro recording stores
    /// commands without executing them, so without the live apply the change
    /// would only take effect after the next reboot.
    ///
    /// - Note: The scan response freezes `advertisedName` as broadcast. A
    ///   later `MWSettings.SetDeviceName` rename won't update it until this
    ///   method is called again (which records an additional macro — macro
    ///   slots are finite, so callers should gate reconfiguration, e.g. on
    ///   whether the board's advertisements already carry a MAC).
    /// - Parameter advertisedName: Name to embed alongside the MAC.
    /// - Returns: The handle of the recorded on-boot macro.
    @discardableResult
    func enableMACAdvertisement(advertisedName: String = "MetaWear") async throws -> MWMacro {
        let mac = try await read(MWSettings.ReadMacAddress()).value
        let payload = try MWMACAdvertisement.scanResponsePayload(
            name: advertisedName, mac: mac
        )
        let command = MWSettings.SetScanResponse(payload)
        let macro = try await recordMacro(executeOnBoot: true) { recorder in
            await recorder.send(command)
        }
        try await send(command)
        return macro
    }

    /// Re-issue the MAC broadcast with a new advertised name (e.g. after
    /// `MWSettings.SetDeviceName`) **without stacking macros**.
    ///
    /// The Macro module offers no per-macro erase — only `ERASE_ALL` — so
    /// this erases every stored macro before re-recording the broadcast
    /// macro. This SDK treats the MAC broadcast as the board's sole macro
    /// owner; if a caller records custom macros alongside it, they must be
    /// re-recorded after calling this.
    @discardableResult
    func updateMACAdvertisement(advertisedName: String) async throws -> MWMacro {
        try await eraseAllMacros()
        return try await enableMACAdvertisement(advertisedName: advertisedName)
    }
}
