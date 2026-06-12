import Testing
@testable import MetaWearApp

// BandwidthAdvisor and SensorSelection are MainActor-isolated (the app's
// default isolation), so the whole suite runs on the main actor.
@MainActor
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
