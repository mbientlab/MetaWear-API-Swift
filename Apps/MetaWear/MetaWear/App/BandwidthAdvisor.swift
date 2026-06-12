import Foundation

enum BandwidthAdvisor {
    static let bleSafeCeilingHz: Double = 100

    static func aggregateHz(_ selections: [SensorSelection]) -> Double {
        selections.reduce(0) { $0 + $1.hz }
    }

    static func isOverCeiling(_ selections: [SensorSelection]) -> Bool {
        aggregateHz(selections) > bleSafeCeilingHz
    }

    static func halved(_ selections: [SensorSelection]) -> [SensorSelection] {
        selections.map { sel in
            var copy = sel
            copy.hz = max(0.78125, sel.hz / 2)
            return copy
        }
    }
}
