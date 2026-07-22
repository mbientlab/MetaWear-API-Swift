import Testing
import Foundation
@testable import MetaWearApp

/// The replay scrubber maps a seconds position to "the sample that was
/// current at that moment" via binary search over the board's own tick
/// clock. Off-by-ones here read as the 3D board jumping ahead of (or
/// lagging) the scrubber, so the boundary behavior is pinned down exactly.
@MainActor
struct ReplayTimelineTests {

    @Test func emptyTimeline_hasNoIndexAndZeroDuration() {
        let t = ReplayTimeline(ticksMs: [])
        #expect(t.index(at: 0) == nil)
        #expect(t.duration == 0)
    }

    @Test func singleSample_alwaysIndexZero() {
        let t = ReplayTimeline(ticksMs: [5000])
        #expect(t.duration == 0)
        #expect(t.index(at: 0) == 0)
        #expect(t.index(at: 99) == 0)
    }

    @Test func ticksNormalizeToZeroBasedSeconds() {
        // Logged ticks count from the board's last RESET, not from the
        // session start — a session recorded an hour after boot starts at
        // tick ~3.6M. The timeline must subtract the first tick.
        let t = ReplayTimeline(ticksMs: [3_600_000, 3_600_500, 3_601_000])
        #expect(t.times == [0, 0.5, 1.0])
        #expect(t.duration == 1.0)
    }

    @Test func indexReturnsLastSampleAtOrBeforePosition() {
        let t = ReplayTimeline(ticksMs: [0, 100, 200, 300])   // 0, 0.1, 0.2, 0.3 s
        #expect(t.index(at: 0) == 0)
        #expect(t.index(at: 0.1) == 1)
        #expect(t.index(at: 0.15) == 1)   // between samples → the earlier one
        #expect(t.index(at: 0.299) == 2)
    }

    @Test func positionsBeyondEndsClampToFirstAndLast() {
        let t = ReplayTimeline(ticksMs: [0, 1000])
        #expect(t.index(at: -5) == 0)
        #expect(t.index(at: 999) == 1)
    }

    @Test func outOfOrderTicksClampMonotonic() {
        // A stray out-of-order tick must not break the binary search's
        // sortedness assumption — the timeline floors it to its predecessor.
        let t = ReplayTimeline(ticksMs: [0, 500, 400, 900])
        #expect(t.times == [0, 0.5, 0.5, 0.9])
        #expect(t.index(at: 0.6) == 2)
    }
}
