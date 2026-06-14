import Testing
import Foundation
@testable import MetaWearApp

@Suite("Live-stream chart downsampling")
@MainActor
struct DownsampleChartTests {

    /// `n` samples whose `f0` equals their index, so the decimated output's
    /// identity and ordering are easy to assert.
    private func samples(_ n: Int) -> [AnyChartSample] {
        (0..<n).map {
            AnyChartSample(time: Date(timeIntervalSince1970: Double($0)), f0: Float($0), channelCount: 1)
        }
    }

    @Test func returnsInputUnchangedWhenAlreadySmall() {
        let input = samples(100)
        let out = StreamSessionViewModel.downsampledForChart(input)
        #expect(out.map(\.f0) == input.map(\.f0))
    }

    @Test func capsLargeInputToTheChartLimit() {
        let out = StreamSessionViewModel.downsampledForChart(samples(600))
        #expect(out.count == 180)
    }

    @Test func preservesFirstAndLastSample() {
        let out = StreamSessionViewModel.downsampledForChart(samples(600))
        #expect(out.first?.f0 == 0)
        #expect(out.last?.f0 == 599)
    }

    @Test func keepsSamplesInOrderAndInRange() {
        let values = StreamSessionViewModel.downsampledForChart(samples(600)).map(\.f0)
        // Uniform forward decimation → strictly non-decreasing, no out-of-range index.
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 599 })
    }

    @Test func handlesEmptyAndSingle() {
        #expect(StreamSessionViewModel.downsampledForChart([]).isEmpty)
        let one = samples(1)
        #expect(StreamSessionViewModel.downsampledForChart(one).map(\.f0) == [0])
    }
}
