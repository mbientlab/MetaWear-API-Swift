import Foundation
import Observation

@Observable
@MainActor
final class Channel: Identifiable {
    let id: SensorKey
    let selection: SensorSelection

    // MARK: - Non-observed hot path
    //
    // The BLE consume task appends to `ring` and bumps `receivedCount` per
    // sample. At 100 Hz × several sensors that's hundreds of writes per
    // second, so these fields are deliberately *not* observed — letting
    // SwiftUI track them per-sample produces enough invalidation churn to
    // visibly lag the chart and the live xyz readout. Instead, the
    // StreamSessionViewModel's 33 ms throttle loop snapshots them into the
    // observed fields below, so the UI updates at a steady 30 fps no
    // matter how fast the board is sampling.

    /// Capture buffer for the chart. Appended-to from the BLE consume task,
    /// snapshotted into `displayBuffer` by the throttle loop.
    @ObservationIgnored
    var ring: RingBuffer<AnyChartSample>

    /// Running count of samples received from the consume task. The
    /// throttle loop copies this into the observed `totalSamples`.
    @ObservationIgnored
    var receivedCount: Int = 0

    // MARK: - Observed (UI-bound) fields
    //
    // All updated exclusively from the throttle loop, never per-sample.

    var displayBuffer: [AnyChartSample] = []
    var latest: AnyChartSample?
    /// Effective sample rate (Hz) over the most recent samples.
    var effectiveHz: Double = 0
    /// Total samples received since the session started, regardless of ring
    /// rollover. Used for the session-summary readout in `LiveStreamView`.
    var totalSamples: Int = 0

    init(selection: SensorSelection, capacity: Int = 600) {
        self.id = selection.id
        self.selection = selection
        self.ring = RingBuffer(capacity: capacity)
    }
}
