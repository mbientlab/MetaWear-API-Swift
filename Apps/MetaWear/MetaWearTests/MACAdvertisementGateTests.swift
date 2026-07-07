import Foundation
import Testing
@testable import MetaWearApp

/// Covers `AppStore.shouldConfigureMACAdvertisement` — the gate that keeps
/// the one-time board configuration from stacking duplicate on-boot macros
/// (macro flash slots are finite).
@MainActor
@Suite("MAC advertisement configuration gate")
struct MACAdvertisementGateTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func configuresFreshUnconfiguredBoard() {
        #expect(AppStore.shouldConfigureMACAdvertisement(
            observedMAC: nil,
            lastAdvertisementSeen: now.addingTimeInterval(-30),
            alreadyConfigured: false,
            now: now
        ))
    }

    @Test
    func skipsBoardAlreadyBroadcastingItsMAC() {
        #expect(!AppStore.shouldConfigureMACAdvertisement(
            observedMAC: "ED:AA:A4:CE:A6:A4",
            lastAdvertisementSeen: now.addingTimeInterval(-30),
            alreadyConfigured: false,
            now: now
        ))
    }

    @Test
    func skipsBoardThisHostAlreadyConfigured() {
        // Covers the reconnect-before-reboot window where the board hasn't
        // re-advertised with the new scan response yet.
        #expect(!AppStore.shouldConfigureMACAdvertisement(
            observedMAC: nil,
            lastAdvertisementSeen: now.addingTimeInterval(-30),
            alreadyConfigured: true,
            now: now
        ))
    }

    @Test
    func skipsWhenNoAdvertisementWasObserved() {
        // Direct reconnect without a scan: the board's current scan-response
        // content is unknown — don't risk a duplicate macro.
        #expect(!AppStore.shouldConfigureMACAdvertisement(
            observedMAC: nil,
            lastAdvertisementSeen: nil,
            alreadyConfigured: false,
            now: now
        ))
    }

    @Test
    func skipsWhenObservationIsStale() {
        #expect(!AppStore.shouldConfigureMACAdvertisement(
            observedMAC: nil,
            lastAdvertisementSeen: now.addingTimeInterval(-16 * 60),
            alreadyConfigured: false,
            now: now
        ))
    }
}
