import Testing
@testable import MetaWearApp

@Suite("BandwidthAdvisor")
struct BandwidthAdvisorTests {

    @Test func aggregateSumsSelections() {
        let selections = [
            SensorSelection(id: .accelerometer, hz: 100),
            SensorSelection(id: .gyroscope, hz: 100),
            SensorSelection(id: .magnetometer, hz: 25)
        ]
        #expect(BandwidthAdvisor.aggregateHz(selections) == 225)
    }

    @Test func isOverCeilingDetectsOverflow() {
        let selections = [
            SensorSelection(id: .accelerometer, hz: 100),
            SensorSelection(id: .gyroscope, hz: 50)
        ]
        #expect(BandwidthAdvisor.isOverCeiling(selections))
    }

    @Test func halvedReducesEveryRate() {
        let selections = [
            SensorSelection(id: .accelerometer, hz: 100),
            SensorSelection(id: .gyroscope, hz: 50)
        ]
        let halved = BandwidthAdvisor.halved(selections)
        #expect(halved.map(\.hz) == [50, 25])
    }
}
