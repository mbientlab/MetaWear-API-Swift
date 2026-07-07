import Foundation
import Testing
@testable import MetaWearApp

/// Covers the advertisement-freshness rule that decides whether a board is
/// "on air": stale and never-seen boards must not render as connectable.
@MainActor
@Suite("Device freshness")
struct DeviceFreshnessTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func recentAdvertisementIsFresh() {
        #expect(DeviceFreshness.isFresh(lastSeen: now.addingTimeInterval(-2), now: now))
    }

    @Test
    func silenceBeyondWindowIsStale() {
        #expect(!DeviceFreshness.isFresh(
            lastSeen: now.addingTimeInterval(-DeviceFreshness.window - 1), now: now
        ))
    }

    @Test
    func neverSeenIsStale() {
        #expect(!DeviceFreshness.isFresh(lastSeen: nil, now: now))
    }

    @Test
    func boundaryIsExclusive() {
        // Exactly `window` old = stale; a hair inside = fresh.
        #expect(!DeviceFreshness.isFresh(
            lastSeen: now.addingTimeInterval(-DeviceFreshness.window), now: now
        ))
        #expect(DeviceFreshness.isFresh(
            lastSeen: now.addingTimeInterval(-DeviceFreshness.window + 0.01), now: now
        ))
    }
}
