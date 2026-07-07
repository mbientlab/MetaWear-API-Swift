//
//  MWMACAdvertisementTests.swift
//  MetaWearTests
//
//  Byte-exact coverage for the MAC-broadcast scan response: the payload the
//  app writes to boards, and the parser the scanner runs on advertisements.
//  The reference MAC is a real board captured during development.
//

import Foundation
import Testing
@testable import MetaWear

@Suite("MAC advertisement")
struct MWMACAdvertisementTests {

    // MARK: - Payload assembly

    @Test
    func payloadLayoutIsNameThenManufacturerData() throws {
        let payload = try MWMACAdvertisement.scanResponsePayload(
            name: "MetaWear", mac: "ED:AA:A4:CE:A6:A4"
        )
        #expect(payload == [
            // len=9, Complete Local Name, "MetaWear"
            0x09, 0x09, 0x4D, 0x65, 0x74, 0x61, 0x57, 0x65, 0x61, 0x72,
            // len=9, Manufacturer Specific, company 0x626D LE, MAC LSB-first
            0x09, 0xFF, 0x6D, 0x62, 0xA4, 0xA6, 0xCE, 0xA4, 0xAA, 0xED,
        ])
        // Must fit a BLE 4.x scan response.
        #expect(payload.count <= 31)
    }

    @Test
    func emptyNameOmitsNameStructure() throws {
        let payload = try MWMACAdvertisement.scanResponsePayload(
            name: "", mac: "ED:AA:A4:CE:A6:A4"
        )
        #expect(payload == [
            0x09, 0xFF, 0x6D, 0x62, 0xA4, 0xA6, 0xCE, 0xA4, 0xAA, 0xED,
        ])
    }

    @Test
    func longNamesAreClampedToFitScanResponse() throws {
        let payload = try MWMACAdvertisement.scanResponsePayload(
            name: String(repeating: "x", count: 40), mac: "ED:AA:A4:CE:A6:A4"
        )
        #expect(payload.count == 31)
        // Name structure holds exactly 19 clamped bytes.
        #expect(payload[0] == 20)   // 19 chars + type byte
        #expect(payload[1] == 0x09)
    }

    @Test
    func invalidMACThrows() {
        #expect(throws: MWError.self) {
            _ = try MWMACAdvertisement.scanResponsePayload(name: "MetaWear", mac: "nope")
        }
        #expect(throws: MWError.self) {
            _ = try MWMACAdvertisement.scanResponsePayload(name: "MetaWear", mac: "ED:AA:A4:CE:A6")
        }
        #expect(throws: MWError.self) {
            _ = try MWMACAdvertisement.scanResponsePayload(name: "MetaWear", mac: "ED:AA:A4:CE:A6:ZZ")
        }
    }

    // MARK: - Parsing

    @Test
    func parsesMbientLabManufacturerData() {
        // CoreBluetooth strips the AD header: data starts at the company ID.
        let data = Data([0x6D, 0x62, 0xA4, 0xA6, 0xCE, 0xA4, 0xAA, 0xED])
        #expect(MWMACAdvertisement.mac(fromManufacturerData: data) == "ED:AA:A4:CE:A6:A4")
    }

    @Test
    func rejectsForeignCompanyIdentifiers() {
        // Apple's company ID — what a board broadcasts in iBeacon mode.
        let iBeacon = Data([0x4C, 0x00, 0x02, 0x15] + Array(repeating: 0 as UInt8, count: 20))
        #expect(MWMACAdvertisement.mac(fromManufacturerData: iBeacon) == nil)
    }

    @Test
    func rejectsTruncatedPayloads() {
        let short = Data([0x6D, 0x62, 0xA4, 0xA6, 0xCE])
        #expect(MWMACAdvertisement.mac(fromManufacturerData: short) == nil)
        #expect(MWMACAdvertisement.mac(fromManufacturerData: Data()) == nil)
    }

    @Test
    func buildParseRoundTrip() throws {
        let mac = "F1:4A:04:29:26:8B"
        let payload = try MWMACAdvertisement.scanResponsePayload(name: "bob", mac: mac)
        // Extract the manufacturer AD structure the way a scanner's radio
        // would deliver it: drop the name structure and the AD header.
        let nameLength = Int(payload[0]) + 1
        let mfgStructure = Array(payload.dropFirst(nameLength))
        let deliveredToCoreBluetooth = Data(mfgStructure.dropFirst(2))
        #expect(MWMACAdvertisement.mac(fromManufacturerData: deliveredToCoreBluetooth) == mac)
    }
}
