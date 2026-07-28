import SwiftUI

/// Maps a scrub position (seconds since session start) to the sample index
/// that was current at that moment. Times come from the board's own tick
/// clock, normalized to a 0-based, non-decreasing series — logged ticks count
/// from the board's last reset, stream-archived ticks are already 0-based.
struct ReplayTimeline: Sendable {
    /// Seconds offsets from the first sample, non-decreasing.
    let times: [Double]
    let duration: Double

    init(ticksMs: [Double]) {
        guard let first = ticksMs.first else {
            times = []
            duration = 0
            return
        }
        var normalized: [Double] = []
        normalized.reserveCapacity(ticksMs.count)
        // Clamp to non-decreasing so a stray out-of-order tick can't make the
        // binary search lie mid-session.
        var floor = 0.0
        for tick in ticksMs {
            floor = max(floor, (tick - first) / 1000)
            normalized.append(floor)
        }
        times = normalized
        duration = floor
    }

    /// Index of the sample playing at `seconds` — the last sample whose time
    /// is ≤ the position, clamped to the ends. Nil only for an empty timeline.
    func index(at seconds: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        if seconds <= times[0] { return 0 }
        if seconds >= duration { return times.count - 1 }
        var lo = 0
        var hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= seconds { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Replays a saved quaternion session in 3D: the same board view the live
/// stream uses, driven by a playback clock instead of BLE, with a scrubber
/// and a speed toggle. `QuaternionRealityView` is a pure function of "latest
/// sample", so replay is just choosing which sample is latest.
struct SessionReplayView: View {
    let samples: [AnyChartSample]
    let timeline: ReplayTimeline

    @State private var position: Double = 0
    @State private var isPlaying = false
    @State private var wasPlayingBeforeScrub = false
    @State private var speed: Double = 1

    private var current: AnyChartSample? {
        timeline.index(at: position).map { samples[$0] }
    }

    var body: some View {
        VStack(spacing: 12) {
            QuaternionRealityView(latest: current)
            controls
        }
        .task(id: isPlaying) {
            await runPlayback()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(isPlaying ? "Pause" : "Play",
                       systemImage: isPlaying ? "pause.fill" : "play.fill") {
                    isPlaying.toggle()
                }
                .buttonStyle(.glassProminent)
                .labelStyle(.iconOnly)
                Slider(value: $position, in: 0...max(timeline.duration, 0.001)) { editing in
                    // Scrubbing pauses the clock so the board tracks the
                    // finger; release resumes if the user was playing.
                    if editing {
                        wasPlayingBeforeScrub = isPlaying
                        isPlaying = false
                    } else if wasPlayingBeforeScrub {
                        wasPlayingBeforeScrub = false
                        isPlaying = true
                    }
                }
                Button(speedLabel) {
                    speed = speed >= 4 ? 1 : speed * 2
                }
                .buttonStyle(.glass)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            }
            HStack {
                Text(timeString(position))
                Spacer()
                Text(timeString(timeline.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private var speedLabel: String {
        "\(speed.formatted(.number.precision(.fractionLength(0))))×"
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Advance the scrub position on a ~30 Hz wall clock while playing. The
    /// step comes from measured elapsed time (not the nominal sleep) so sleep
    /// jitter can't slow the replay below real time.
    private func runPlayback() async {
        guard isPlaying else { return }
        if position >= timeline.duration { position = 0 }
        let clock = ContinuousClock()
        var last = clock.now
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let now = clock.now
            let elapsed = last.duration(to: now)
            let dt = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            last = now
            position = min(timeline.duration, position + dt * speed)
            if position >= timeline.duration {
                isPlaying = false
            }
        }
    }
}
