import Foundation
import Observation
import MetaWear
import MetaWearPersistence

/// Drives the live-streaming screen.
///
/// Owns the active sensor streams, per-sensor chart channels, pause/resume
/// lifecycle, and optional archive-to-history flow for the in-memory ring
/// buffers. Each stream consumes `MetaWearDevice.startStream(_:)` on a
/// background task and throttles UI updates through `Channel.displayBuffer`.
@Observable
@MainActor
final class StreamSessionViewModel {
    private let device: MetaWearDevice
    private let persistence: MWPersistenceStore
    var channels: [Channel] = []
    var isStreaming: Bool = false
    /// When true, BLE streams are torn down (`stopStreaming` sent to every
    /// active sensor) so the board stops sampling and saves battery. Ring
    /// buffers and `totalSamples` are preserved across the pause; resuming
    /// re-spawns the same streams and the chart picks back up.
    var isPaused: Bool = false
    var lastError: AppError?
    /// Wall-clock when streaming first started. `nil` before start or after
    /// stop. Preserved across pauses so duration keeps counting the period
    /// the session has been *active*.
    var startedAt: Date?
    /// Sum of `totalSamples` across all channels. Updated by the throttle
    /// loop so the summary readout doesn't refresh on every individual
    /// sample append.
    var totalSamples: Int = 0

    private var streamTasks: [SensorKey: Task<Void, Never>] = [:]
    private var stopHandlers: [SensorKey: @Sendable () async throws -> Void] = [:]
    private var throttleTask: Task<Void, Never>?
    /// Selections last passed to `start(_:)`. Held so `resume()` can re-spawn
    /// the same set of streams after a pause has torn them down.
    private var selections: [SensorSelection] = []
    /// Guard against double-tapping the Pause toolbar button while the
    /// previous pause/resume task is still tearing down or re-starting
    /// BLE streams.
    var isTogglingPause: Bool = false

    init(device: MetaWearDevice, persistence: MWPersistenceStore) {
        self.device = device
        self.persistence = persistence
    }

    /// True once the current buffer has been saved to Session History. Set
    /// after `archiveToHistory()` succeeds so the same set of samples isn't
    /// written twice if multiple disappear-events fire.
    private var hasArchived = false

    func start(_ selections: [SensorSelection]) async {
        guard !isStreaming else { return }
        self.selections = selections
        channels = selections.map { Channel(selection: $0) }
        isStreaming = true
        isPaused = false   // belt-and-suspenders: any stale pause flag from a
                            // previous session would otherwise leave the throttle
                            // skipping the displayBuffer copy and the chart blank.
        startedAt = .now
        totalSamples = 0
        hasArchived = false

        for selection in selections {
            await spawnStream(for: selection)
        }
        startThrottle()
    }

    func stop() async {
        isStreaming = false
        isPaused = false
        startedAt = nil
        throttleTask?.cancel()
        throttleTask = nil

        await tearDownStreams()
        selections = []
    }

    /// Pause sends `stopStreaming` to every active sensor so the board stops
    /// sampling (and stops burning battery). Ring buffers and `totalSamples`
    /// are preserved across the pause; `resume()` re-spawns the same set of
    /// streams and the chart picks back up where it left off, with a small
    /// gap in the timeline for the paused interval.
    func pause() async {
        guard isStreaming, !isPaused, !isTogglingPause else { return }
        isTogglingPause = true
        defer { isTogglingPause = false }
        // Flip the flag BEFORE the BLE tear-down. The throttle loop reads
        // `isPaused` and stops mirroring the ring into `displayBuffer`, so
        // the chart freezes instantly on tap. The actual stop writes +
        // `unsubscribe` then happen in the background; any samples that
        // land in the ring during the transition stay there but don't show
        // until the user resumes.
        isPaused = true
        await tearDownStreams()
    }

    func resume() async {
        guard isStreaming, isPaused, !isTogglingPause else { return }
        isTogglingPause = true
        defer { isTogglingPause = false }
        // Unfreeze the chart before re-spawning the BLE streams so the
        // existing trace becomes "live" again the moment new samples land
        // — no gap waiting for the start handshake to finish.
        isPaused = false
        for selection in selections {
            await spawnStream(for: selection)
        }
    }

    func togglePause() {
        Task {
            if isPaused {
                await resume()
            } else {
                await pause()
            }
        }
    }

    /// Cancel all stream tasks and send each sensor its stop command.
    /// Shared by `stop()` and `pause()` so the BLE tear-down logic lives
    /// in exactly one place.
    ///
    /// Order matters: run each sensor's `stopHandler` (which writes the
    /// device's stop command and `proto.unsubscribe`s) **before** cancelling
    /// the consume task. The unsubscribe finishes the underlying notify
    /// stream, which is what naturally exits the consume task's for-await.
    /// If we cancelled first and then awaited stop, a sensor whose
    /// `stopCommand` is interpreted as a no-op by the firmware (or whose
    /// rawStream keeps emitting briefly after the stop write) could keep
    /// feeding the consume task with samples before cancellation actually
    /// took effect — symptom seen on the barometer.
    private func tearDownStreams() async {
        for (_, stop) in stopHandlers {
            try? await stop()
        }
        stopHandlers.removeAll()
        for (_, task) in streamTasks {
            task.cancel()
        }
        streamTasks.removeAll()
    }

    /// Terminate the session after a stream error (most commonly an
    /// unexpected BLE disconnect, which fails every active stream at once).
    /// Without this, `isStreaming` stayed true with dead streams — a zombie
    /// session whose UI claimed to be live and whose stale `stopHandlers`
    /// pointed at a gone device. The stop writes inside `tearDownStreams`
    /// are best-effort (`try?`), so they fail fast when the device is gone
    /// and still do the right thing when only a single stream errored.
    private func failSession(with error: Error) async {
        lastError = AppError(error: error)
        guard isStreaming else { return }
        isStreaming = false
        isPaused = false
        startedAt = nil
        throttleTask?.cancel()
        throttleTask = nil
        await tearDownStreams()
        selections = []
    }

    private func spawnStream(for selection: SensorSelection) async {
        let key = selection.id
        guard let channel = channels.first(where: { $0.id == key }) else { return }
        let modules = await device.modules

        switch key {
        case .accelerometer:
            let impl = modules[.accelerometer]?.implementation ?? 1
            let rangeG = Float(selection.range ?? 2)
            guard let accel = MWAccelerometer.make(impl: impl, odrHz: selection.hz, rangeG: rangeG) else { return }
            switch accel {
            case .bmi160(let s):
                stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
                streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
            case .bmi270(let s):
                stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
                streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
            }

        case .gyroscope:
            let impl = modules[.gyro]?.implementation ?? 0
            let rangeDPS = Float(selection.range ?? 2000)
            guard let gyro = MWGyroscope.make(impl: impl, odrHz: selection.hz, rangeDPS: rangeDPS) else { return }
            switch gyro {
            case .bmi160(let s):
                stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
                streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
            case .bmi270(let s):
                stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
                streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
            }

        case .magnetometer:
            // Bosch's "regular" preset is locked at 10 Hz — bypass it and pick
            // the BMM150 ODR closest to the user's selected rate. xy=9 / z=15
            // matches the regular preset's noise/power trade-off and fits
            // comfortably within even the 30 Hz conversion budget.
            let odr = MWMagnetometer.ODR.allCases.min {
                abs($0.hz - selection.hz) < abs($1.hz - selection.hz)
            } ?? .hz10
            let s = MWMagnetometer(xyReps: 9, zReps: 15, odr: odr)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)

        case .barometer:
            let s = MWBarometer()
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)

        case .temperature:
            // Default to channel 0 (NRF die) — always present without an
            // external-thermistor configure handshake. The SensorConfigView
            // exposes a picker for boards with multiple channels.
            let channelIndex = UInt8(selection.channel ?? 0)
            let s = MWThermometer(channel: channelIndex)
            streamTasks[key] = poll(s, interval: pollInterval(forHz: selection.hz), into: channel, convert: AnyChartSample.from)

        case .humidity:
            let s = MWHumidity()
            streamTasks[key] = poll(s, interval: pollInterval(forHz: selection.hz), into: channel, convert: AnyChartSample.from)

        case .ambientLight:
            // Default LTR329 config — gain x1, integration 100 ms, rate 500 ms.
            // The sensor's own measurement rate drives sample cadence; the
            // configured `hz` is informational only.
            let s = MWAmbientLight()
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel) { ts in
                // Raw is milli-lux; chart in lux so the y-axis stays readable.
                AnyChartSample(time: ts.time, f0: Float(ts.value) / 1000, channelCount: 1)
            }

        case .sensorFusion(let output):
            let chip = MWSensorFusionChip(accImpl: modules[.accelerometer]?.implementation ?? 1) ?? .bmi160
            await spawnSensorFusion(output: output, chip: chip, key: key, channel: channel)
        }
    }

    private func spawnSensorFusion(
        output: SensorFusionOutput,
        chip: MWSensorFusionChip,
        key: SensorKey,
        channel: Channel
    ) async {
        switch output {
        case .quaternion:
            let s = MWSensorFusionQuaternion(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
        case .eulerAngles:
            let s = MWSensorFusionEuler(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
        case .gravity:
            let s = MWSensorFusionGravity(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
        case .linearAcceleration:
            let s = MWSensorFusionLinearAcceleration(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel, convert: AnyChartSample.from)
        case .correctedAcceleration:
            let s = MWSensorFusionCorrectedAcc(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel) { ts in
                AnyChartSample(time: ts.time, f0: ts.value.x, f1: ts.value.y, f2: ts.value.z, channelCount: 3)
            }
        case .correctedAngularVelocity:
            let s = MWSensorFusionCorrectedGyro(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel) { ts in
                AnyChartSample(time: ts.time, f0: ts.value.x, f1: ts.value.y, f2: ts.value.z, channelCount: 3)
            }
        case .correctedMagneticField:
            let s = MWSensorFusionCorrectedMag(chip: chip)
            stopHandlers[key] = { [device] in try await device.stopStreaming(s) }
            streamTasks[key] = consume(s, into: channel) { ts in
                AnyChartSample(time: ts.time, f0: ts.value.x, f1: ts.value.y, f2: ts.value.z, channelCount: 3)
            }
        }
    }

    /// Convert a selected Hz to a Duration for `device.poll(_:every:)`.
    /// Clamps to ≥ 100 ms so a stray `0` from the picker can't busy-loop the board.
    private func pollInterval(forHz hz: Double) -> Duration {
        let seconds = max(0.1, hz > 0 ? 1.0 / hz : 1.0)
        return .milliseconds(Int(seconds * 1000))
    }

    private func consume<S: MWStreamable>(
        _ sensor: S,
        into channel: Channel,
        convert: @escaping @MainActor @Sendable (Timestamped<S.Sample>) -> AnyChartSample
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                let stream = try await self?.device.startStream(sensor)
                guard let stream else { return }
                for try await sample in stream {
                    // Drop any samples that arrive after Stop / Pause:
                    // the BLE notify pipeline keeps emitting a few
                    // packets after the stop write because the board
                    // takes a moment to actually halt sampling.
                    guard let self, self.isStreaming, !self.isPaused else { continue }
                    let any = convert(sample)
                    // Append to the non-observed ring + counter — the
                    // throttle loop hoists these into the observed
                    // `displayBuffer` / `latest` / `totalSamples` once
                    // every 33 ms. Touching the observed fields
                    // directly here would fire a SwiftUI invalidation
                    // per sample and stall the UI at high sample rates.
                    channel.ingest(any)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.failSession(with: error)
            }
        }
    }

    /// Drive a pollable readable on a fixed interval. Cancelling the returned
    /// task cancels the underlying poll stream — no device-side stop command
    /// is needed because polling never enables a hardware notification.
    private func poll<P: MWPollable>(
        _ sensor: P,
        interval: Duration,
        into channel: Channel,
        convert: @escaping @MainActor @Sendable (Timestamped<P.Sample>) -> AnyChartSample
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let device = self?.device else { return }
            do {
                for try await sample in device.poll(sensor, every: interval) {
                    // Same gate as `consume` — drop drained samples
                    // that arrive after Stop / Pause so the readout
                    // freezes with the chart.
                    guard let self, self.isStreaming, !self.isPaused else { continue }
                    let any = convert(sample)
                    // Non-observed write — throttle loop publishes.
                    channel.ingest(any)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.failSession(with: error)
            }
        }
    }

    private func startThrottle() {
        throttleTask?.cancel()
        throttleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                // Pause is flipped synchronously on tap, before BLE
                // tear-down — skipping the update here gives the chart
                // an instant freeze instead of waiting for the stop
                // writes to drain the in-flight notification pipeline.
                if self.isPaused { continue }
                var aggregate = 0
                for channel in self.channels {
                    let elements = channel.ring.elements
                    let received = channel.receivedCount
                    // One observed-field write per channel per tick (33
                    // ms), instead of three per sample on the consume
                    // task. At 100 Hz × 3 sensors that's ~30 ticks/sec
                    // total UI churn rather than ~900 invalidations/sec.
                    //
                    // `displayRing` is already decimated to a screen-
                    // resolvable point count and only ever appended to, so
                    // snapshotting it yields a smooth scrolling trace whose
                    // older points never move. `latest` and the archived
                    // `ring` stay full-resolution.
                    channel.displayBuffer = channel.displayRing.elements
                    channel.latest = elements.last
                    channel.effectiveHz = Self.effectiveHz(from: elements)
                    channel.totalSamples = received
                    aggregate &+= received
                }
                self.totalSamples = aggregate
            }
        }
    }

    /// Effective sample rate from the last ~32 samples in a ring buffer.
    /// Looks at the elapsed time between the first and last sample in that
    /// window; returns 0 when there aren't enough samples or the timestamps
    /// haven't separated yet. Reflects actual BLE delivery — drops or
    /// back-pressure show up as a lower number than the configured ODR.
    nonisolated private static func effectiveHz(from samples: [AnyChartSample]) -> Double {
        let window = samples.suffix(32)
        guard window.count >= 2,
              let first = window.first?.time,
              let last = window.last?.time else { return 0 }
        let interval = last.timeIntervalSince(first)
        guard interval > 0 else { return 0 }
        return Double(window.count - 1) / interval
    }

    // MARK: - Archive to Session History

    /// Save each non-empty channel's ring buffer to `MWPersistenceStore` as a
    /// session. One session per channel — that's how logged sessions look,
    /// and `SessionDetailView` is already wired to plot a single sensor kind
    /// at a time. Idempotent: subsequent calls within the same session are
    /// no-ops, so navigating away and coming back doesn't double-archive.
    func archiveToHistory() async {
        guard !hasArchived else { return }
        guard channels.contains(where: { !$0.ring.elements.isEmpty }) else { return }
        guard let info = await device.deviceInfo else { return }
        let deviceID = device.identifier
        for channel in channels {
            let samples = channel.ring.elements
            guard !samples.isEmpty else { continue }
            do {
                try await save(samples: samples, channel: channel, deviceID: deviceID, deviceInfo: info)
            } catch {
                lastError = AppError(error: error)
            }
        }
        hasArchived = true
    }

    /// Dispatch on `channel.id` to the right persistable type. Each branch
    /// builds `[MWLoggedSample<T>]` from the type-erased `AnyChartSample`s
    /// and calls `saveSession`. `tickMs` is computed relative to the
    /// session's `startedAt` since streamed samples don't carry the board's
    /// own tick count.
    private func save(
        samples: [AnyChartSample],
        channel: Channel,
        deviceID: UUID,
        deviceInfo: MWDeviceInformation
    ) async throws {
        let started = startedAt ?? samples.first?.time ?? .now
        func tick(_ s: AnyChartSample) -> Double { s.time.timeIntervalSince(started) * 1000 }
        let label = channel.selection.label

        switch channel.id {
        case .accelerometer, .gyroscope, .magnetometer,
             .sensorFusion(.linearAcceleration), .sensorFusion(.gravity):
            let typed = samples.map { s in
                MWLoggedSample(date: s.time, tickMs: tick(s),
                               value: CartesianFloat(x: s.f0, y: s.f1, z: s.f2))
            }
            _ = try await persistence.saveSession(deviceID: deviceID, deviceInfo: deviceInfo,
                                            sensorKind: CartesianFloat.persistenceKind,
                                            samples: typed, label: label)

        case .sensorFusion(.correctedAcceleration),
             .sensorFusion(.correctedAngularVelocity),
             .sensorFusion(.correctedMagneticField):
            let typed = samples.map { s in
                MWLoggedSample(date: s.time, tickMs: tick(s),
                               value: CorrectedCartesianFloat(x: s.f0, y: s.f1, z: s.f2, accuracy: 0))
            }
            _ = try await persistence.saveSession(deviceID: deviceID, deviceInfo: deviceInfo,
                                            sensorKind: CorrectedCartesianFloat.persistenceKind,
                                            samples: typed, label: label)

        case .sensorFusion(.quaternion):
            let typed = samples.map { s in
                MWLoggedSample(date: s.time, tickMs: tick(s),
                               value: Quaternion(w: s.f0, x: s.f1, y: s.f2, z: s.f3))
            }
            _ = try await persistence.saveSession(deviceID: deviceID, deviceInfo: deviceInfo,
                                            sensorKind: Quaternion.persistenceKind,
                                            samples: typed, label: label)

        case .sensorFusion(.eulerAngles):
            let typed = samples.map { s in
                MWLoggedSample(date: s.time, tickMs: tick(s),
                               value: EulerAngles(heading: s.f0, pitch: s.f1, roll: s.f2, yaw: s.f3))
            }
            _ = try await persistence.saveSession(deviceID: deviceID, deviceInfo: deviceInfo,
                                            sensorKind: EulerAngles.persistenceKind,
                                            samples: typed, label: label)

        case .barometer, .temperature, .humidity, .ambientLight:
            let typed = samples.map { s in
                MWLoggedSample(date: s.time, tickMs: tick(s), value: s.f0)
            }
            _ = try await persistence.saveSession(deviceID: deviceID, deviceInfo: deviceInfo,
                                            sensorKind: Float.persistenceKind,
                                            samples: typed, label: label)
        }
    }

}
