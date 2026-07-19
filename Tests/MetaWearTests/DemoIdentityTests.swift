//
//  DemoIdentityTests.swift
//  MetaWearTests
//
//  The demo fleet's identity contract. Multi-board flows (group logging,
//  per-board attribution) are validated in the simulator against several
//  DemoBLETransport instances — that only works if each board wears a
//  distinct, STABLE identity, and board 0 stays byte-for-byte compatible
//  with the legacy single demo device (its UUID may be persisted in
//  UserDefaults maps from older builds).
//

import Foundation
import Testing
@testable import MetaWear

@Suite("DemoBLETransport.Identity")
struct DemoIdentityTests {

    @Test
    func boardZeroIsTheLegacyDemoDevice() {
        let board = DemoBLETransport.Identity.board(0)
        #expect(board.identifier == DemoBLETransport.deviceIdentifier)
        #expect(board.serial == "DEMO01")
        #expect(board.macLSBFirst == [0x01, 0xE0, 0x0D, 0x0E, 0x3D, 0xDE])
        #expect(board.phaseOffset == 0)
    }

    @Test
    func fleetIdentitiesAreDistinctAndStable() {
        let fleet = (0..<3).map { DemoBLETransport.Identity.board($0) }
        #expect(Set(fleet.map(\.identifier)).count == 3)
        #expect(fleet.map(\.serial) == ["DEMO01", "DEMO02", "DEMO03"])
        #expect(Set(fleet.map(\.macLSBFirst)).count == 3)
        // Stable across calls — persisted UUID maps depend on it.
        #expect(DemoBLETransport.Identity.board(2) == fleet[2])
    }

    @Test
    func transportServesItsIdentitySerial() async throws {
        let transport = DemoBLETransport(identity: .board(1))
        let serial = try await transport.read(from: MWUUIDs.serialNumber)
        #expect(String(decoding: serial, as: UTF8.self) == "DEMO02")
    }

    /// The waveform phase offset must NOT skew the logging clock: each
    /// board's `logReferenceDate` derives from the (0x0B, 0x04) tick, so a
    /// leaked offset would misalign "simultaneous" demo logs across the
    /// fleet by up to 1.8 s.
    @Test
    func loggingClockIsWallTrueAcrossTheFleet() async throws {
        var ticks: [UInt32] = []
        for index in [0, 2] {
            let transport = DemoBLETransport(identity: .board(index))
            let stream = await transport.notifications(from: MWUUIDs.notify)
            try await transport.connect(to: DemoBLETransport.Identity.board(index).identifier)
            try await transport.write(Data([0x0B, 0x84]), to: MWUUIDs.command, type: .withResponse)
            var iterator = stream.makeAsyncIterator()
            let packet = try await iterator.next()
            let bytes = try #require(packet)
            #expect(bytes.count == 7)
            ticks.append(
                UInt32(bytes[2]) | (UInt32(bytes[3]) << 8)
                    | (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 24)
            )
        }
        // Board 2's phase offset is 1.8 s ≈ 1229 ticks; wall-true clocks
        // read within a handful of ticks of each other (test overhead).
        let delta = ticks[0] > ticks[1] ? ticks[0] - ticks[1] : ticks[1] - ticks[0]
        #expect(delta < 100, "fleet logging clocks diverged by \(delta) ticks")
    }

    @Test
    func transportServesItsIdentityMAC() async throws {
        let transport = DemoBLETransport(identity: .board(2))
        let stream = await transport.notifications(from: MWUUIDs.notify)
        try await transport.connect(to: DemoBLETransport.Identity.board(2).identifier)
        // Settings MAC read: [0x11, 0x8B] → [0x11, 0x8B, 0x01(type)] + 6-byte LE MAC
        try await transport.write(Data([0x11, 0x8B]), to: MWUUIDs.command, type: .withResponse)
        var iterator = stream.makeAsyncIterator()
        let packet = try await iterator.next()
        #expect(packet == Data([0x11, 0x8B, 0x01, 0x03, 0xE0, 0x0D, 0x0E, 0x3D, 0xDE]))
    }
}
