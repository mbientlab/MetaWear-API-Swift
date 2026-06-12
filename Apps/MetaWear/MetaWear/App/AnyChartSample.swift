import Foundation
import MetaWear

/// Type-erased sample used by chart buffers. Stores up to four float channels
/// plus an optional accuracy byte so any sensor value (Cartesian, Quaternion,
/// Euler, scalar) can drop into the same `Chart`.
struct AnyChartSample: Sendable, Identifiable {
    let id: UInt64
    let time: Date
    let f0: Float
    let f1: Float
    let f2: Float
    let f3: Float
    let channelCount: UInt8

    init(time: Date, f0: Float, f1: Float = 0, f2: Float = 0, f3: Float = 0, channelCount: UInt8) {
        self.id = AnyChartSample.nextID()
        self.time = time
        self.f0 = f0
        self.f1 = f1
        self.f2 = f2
        self.f3 = f3
        self.channelCount = channelCount
    }

    private static let counter = Counter()

    private static func nextID() -> UInt64 {
        counter.next()
    }

    private final class Counter: @unchecked Sendable {
        private var value: UInt64 = 0
        private let lock = NSLock()
        func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return value
        }
    }
}

extension AnyChartSample {
    static func from(_ ts: Timestamped<CartesianFloat>) -> AnyChartSample {
        AnyChartSample(time: ts.time, f0: ts.value.x, f1: ts.value.y, f2: ts.value.z, channelCount: 3)
    }

    static func from(_ ts: Timestamped<Quaternion>) -> AnyChartSample {
        AnyChartSample(time: ts.time, f0: ts.value.w, f1: ts.value.x, f2: ts.value.y, f3: ts.value.z, channelCount: 4)
    }

    static func from(_ ts: Timestamped<EulerAngles>) -> AnyChartSample {
        AnyChartSample(time: ts.time, f0: ts.value.heading, f1: ts.value.pitch, f2: ts.value.roll, f3: ts.value.yaw, channelCount: 4)
    }

    static func from(_ ts: Timestamped<Float>) -> AnyChartSample {
        AnyChartSample(time: ts.time, f0: ts.value, channelCount: 1)
    }

    static func from<V: BinaryInteger>(_ ts: Timestamped<V>) -> AnyChartSample {
        AnyChartSample(time: ts.time, f0: Float(ts.value), channelCount: 1)
    }

    // MARK: - From logged samples (read back from SwiftData)

    static func from(_ s: MWLoggedSample<CartesianFloat>) -> AnyChartSample {
        AnyChartSample(time: s.date, f0: s.value.x, f1: s.value.y, f2: s.value.z, channelCount: 3)
    }

    static func from(_ s: MWLoggedSample<Quaternion>) -> AnyChartSample {
        AnyChartSample(time: s.date, f0: s.value.w, f1: s.value.x, f2: s.value.y, f3: s.value.z, channelCount: 4)
    }

    static func from(_ s: MWLoggedSample<EulerAngles>) -> AnyChartSample {
        AnyChartSample(time: s.date, f0: s.value.heading, f1: s.value.pitch, f2: s.value.roll, f3: s.value.yaw, channelCount: 4)
    }

    static func from(_ s: MWLoggedSample<Float>) -> AnyChartSample {
        AnyChartSample(time: s.date, f0: s.value, channelCount: 1)
    }
}
