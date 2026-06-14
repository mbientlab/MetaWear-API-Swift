import Testing
import Foundation
@testable import MetaWearApp

@Suite("Live-stream channel decimation")
@MainActor
struct ChannelDecimationTests {

    /// A sample whose `f0` equals `i`, so kept points are easy to identify.
    private func sample(_ i: Int) -> AnyChartSample {
        AnyChartSample(time: Date(timeIntervalSince1970: Double(i)), f0: Float(i), channelCount: 1)
    }

    private func channel(hz: Double) -> Channel {
        Channel(selection: SensorSelection(id: .accelerometer, hz: hz, range: 2, channel: nil))
    }

    @Test func strideScalesWithConfiguredRate() {
        #expect(channel(hz: 200).displayStride == 7)   // 200/30 ≈ 6.67 → 7
        #expect(channel(hz: 100).displayStride == 3)   // 3.33 → 3
        #expect(channel(hz: 50).displayStride == 2)    // 1.67 → 2
        #expect(channel(hz: 25).displayStride == 1)    // 0.83 → 1 (no decimation)
        #expect(channel(hz: 1).displayStride == 1)     // never below 1
    }

    @Test func ingestKeepsFullResButThinsTheDisplaySeries() {
        let ch = channel(hz: 100)        // stride 3
        for i in 0..<30 { ch.ingest(sample(i)) }
        #expect(ch.ring.count == 30)             // full resolution preserved (for archive)
        #expect(ch.receivedCount == 30)
        #expect(ch.displayRing.count == 10)      // 1 of every 3 plotted
    }

    /// The whole point of the fix: previously-displayed points keep their exact
    /// values as new samples arrive (they scroll, they don't get recomputed).
    @Test func displayedPointsAreRealAndStable() {
        let ch = channel(hz: 100)        // stride 3 → keeps the 3rd, 6th, 9th… ingested
        for i in 0..<9 { ch.ingest(sample(i)) }
        #expect(ch.displayRing.elements.map(\.f0) == [2, 5, 8])

        for i in 9..<12 { ch.ingest(sample(i)) }     // adds i=11 only
        // The earlier points are byte-for-byte unchanged; only a new one appended.
        #expect(ch.displayRing.elements.map(\.f0) == [2, 5, 8, 11])
    }

    @Test func lowRateSensorKeepsEverySample() {
        let ch = channel(hz: 1)          // stride 1
        for i in 0..<5 { ch.ingest(sample(i)) }
        #expect(ch.displayRing.elements.map(\.f0) == [0, 1, 2, 3, 4])
    }
}
