import Foundation
import Observation

/// One charted sensor stream in a live session.
///
/// Separates high-frequency sample ingestion from observed UI state: raw
/// samples accumulate in an ignored ring buffer, then the stream view model
/// snapshots into observed fields at a fixed UI cadence.
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

    /// Full-resolution capture buffer. Appended-to from the BLE consume task;
    /// drives archive-to-history, `latest`, and the true-rate readout.
    @ObservationIgnored
    var ring: RingBuffer<AnyChartSample>

    /// Capped, *decimated* copy of `ring` — the actual plotted series. Fed one
    /// real sample at a time (1 of every `displayStride`) and only ever
    /// appended to, so older points scroll FIFO and keep their values instead
    /// of jumping around the way a per-frame re-downsample would. The throttle
    /// loop snapshots it into `displayBuffer`.
    @ObservationIgnored
    var displayRing: RingBuffer<AnyChartSample>

    /// Keep 1 of every `displayStride` samples in `displayRing`. A live chart
    /// card resolves only a few hundred points, so a high-rate sensor (e.g.
    /// 200 Hz accel) is thinned to ~30 plotted Hz; low-rate sensors keep every
    /// sample (stride 1). Set once from the configured rate.
    let displayStride: Int

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
        // Plot at most ~30 Hz: thin high-rate sensors, keep low-rate ones whole.
        self.displayStride = max(1, Int((selection.hz / 30).rounded()))
        self.displayRing = RingBuffer(capacity: 180)
    }

    /// Ingest a freshly-received sample. Always stored full-resolution in
    /// `ring`; every `displayStride`-th sample is also mirrored into the
    /// plotted `displayRing`. Both buffers are `@ObservationIgnored`, so this
    /// stays off SwiftUI's per-sample invalidation path — the throttle loop
    /// publishes to the observed fields at a fixed cadence.
    func ingest(_ sample: AnyChartSample) {
        ring.append(sample)
        receivedCount &+= 1
        if receivedCount % displayStride == 0 {
            displayRing.append(sample)
        }
    }
}
