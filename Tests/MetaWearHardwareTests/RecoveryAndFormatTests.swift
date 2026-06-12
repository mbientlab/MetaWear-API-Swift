import Testing
import Foundation
import MetaWear

// MARK: - Hardware verification of recovery flows and wire formats
//
// Covers the remaining "verified on paper, never on silicon" items:
//
//  - **MAC read format** on current firmware (7-byte payload with a leading
//    address-type byte — the parser handles 6 and 7; this pins which one
//    1.7.x actually sends by checking the parse succeeds and looks sane).
//  - **Logger-slot enumeration speed** after the probe-timeout change
//    (5 s → 1 s): the enumeration must still find every chunk, and the
//    whole scan must finish fast.
//  - **High-ODR log reassembly**: at 800 Hz two samples regularly share one
//    1.465 ms tick. The queue-pairing decoder must keep them all — the old
//    (resetUID, tick) grouping collapsed colliding samples and would lose
//    a large fraction of this test's data.
//  - **Unexpected-disconnect behaviour**: a debug reset mid-stream must
//    terminate the sample stream promptly and fire `onUnexpectedDisconnect`.

private extension MetaWearDevice {
    /// `onUnexpectedDisconnect` is an actor-isolated stored property; this
    /// mirrors the app target's setter extension for use from tests.
    func setTestDisconnectHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        onUnexpectedDisconnect = handler
    }
}

@Suite("Hardware — Recovery & Wire Formats", .serialized)
struct RecoveryAndFormatTests {

    // MARK: MAC format

    @Test @MainActor
    func macAddress_parsesOnCurrentFirmware() async throws {
        try await withConnectedDevice { device in
            let mac = try await device.read(MWMACAddress()).value
            let firmware = await device.deviceInfo?.firmwareRevision ?? "?"
            print("  MAC: \(mac)   firmware: \(firmware)")

            let pattern = /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/
            #expect(mac.wholeMatch(of: pattern) != nil, "Malformed MAC: \(mac)")
            #expect(mac != "00:00:00:00:00:00")
            // A misapplied 6-vs-7-byte offset shifts the address-type byte
            // (0x01 on current firmware) into the low octet — flag it.
            #expect(!mac.hasSuffix(":01") || !mac.hasPrefix("00:"),
                    "MAC looks like an off-by-one parse of the address-type byte: \(mac)")
        }
    }

    // MARK: Logger-slot enumeration

    /// With a 2-chunk accelerometer logger installed, enumeration must find
    /// both chunks, complete quickly (the trailing empty-slot probe now times
    /// out at 1 s instead of 5 s), and feed the pre-fetched `recoverLoggers`
    /// overload without error.
    @Test @MainActor
    func queryActiveLoggers_findsAllChunks_withinProbeBudget() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            guard let accel = await device.makeAccelerometer(odrHz: 50, rangeG: 8) else {
                throw MWError.operationFailed("No accelerometer on this board")
            }

            func run<L: MWLoggable>(_ sensor: L) async throws {
                try await device.startLogging(sensor)
                try await device.stopLogging(sensor)

                let started = ContinuousClock.now
                let active = try await device.queryActiveLoggers()
                let elapsed = ContinuousClock.now - started

                print("  queryActiveLoggers: \(active.count) chunks in \(elapsed)")
                #expect(active.count >= 2, "Expected the 2-chunk accel logger, found \(active.count)")
                // 2 populated probes + 1 trailing timed-out probe at 1 s each,
                // plus BLE round trips. 4 s of headroom; the old 5 s probe
                // timeout alone would blow straight through this.
                #expect(elapsed < .seconds(4), "Enumeration took \(elapsed) — probe timeout regression?")

                try await device.recoverLoggers(for: sensor, using: active)
            }

            switch accel {
            case .bmi160(let s): try await run(s)
            case .bmi270(let s): try await run(s)
            }
            try await resetBoardState(device)
        }
    }

    // MARK: High-ODR log reassembly

    /// Log the accelerometer at 800 Hz for ~1.5 s, download, and decode.
    /// At 800 Hz the inter-sample period (1.25 ms) is shorter than one log
    /// tick (≈1.465 ms), so many consecutive samples share a tick. The
    /// queue-pairing decoder keeps every sample; the old tick-grouping
    /// decoder collapsed colliders and would fall far below the threshold.
    @Test @MainActor
    func highODRLogging_800Hz_keepsSameTickSamples() async throws {
        try await withConnectedDevice { device in
            try await resetBoardState(device)
            guard let accel = await device.makeAccelerometer(odrHz: 800, rangeG: 8) else {
                throw MWError.operationFailed("No accelerometer on this board")
            }

            func run<L: MWLoggable>(_ sensor: L) async throws where L.Sample == CartesianFloat {
                try await device.startLogging(sensor)
                try await Task.sleep(for: .milliseconds(1500))
                try await device.stopLogging(sensor)

                var decoded: [MWLoggedSample<CartesianFloat>] = []
                let stream = try await device.downloadLogs(sensor)
                for try await progress in stream {
                    decoded = progress.data
                }

                let expected = Int(800 * 1.5)
                print("  800 Hz × 1.5 s: decoded \(decoded.count) samples (expected ≈\(expected))")
                #expect(decoded.count > Int(Double(expected) * 0.7),
                        "Only \(decoded.count) of ≈\(expected) samples decoded — same-tick collapse?")

                // Ticks must be non-decreasing after reassembly.
                let ticks = decoded.map(\.tickMs)
                #expect(ticks == ticks.sorted(), "Decoded sample timestamps are not monotonic")

                // Sanity: a resting board should read ≈1 g magnitude.
                if let sample = decoded.last?.value {
                    let magnitude = (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
                    #expect(magnitude > 0.5 && magnitude < 1.5,
                            "Resting magnitude \(magnitude) g — scale/range decode issue?")
                }
            }

            switch accel {
            case .bmi160(let s): try await run(s)
            case .bmi270(let s): try await run(s)
            }
            try await resetBoardState(device)
        }
    }

    // MARK: Unexpected disconnect mid-stream

    /// Accumulates callback state on the main actor for the deadline loop.
    @MainActor
    private final class DisconnectFlag {
        var fired = false
    }

    /// Start a live stream, then yank the rug with a debug reset. The sample
    /// stream must terminate (not hang), `onUnexpectedDisconnect` must fire,
    /// and the device must land in `.disconnected`.
    @Test @MainActor
    func unexpectedReset_terminatesStream_andFiresCallback() async throws {
        let device = try await nearbyDevice()
        try await device.connect()

        let flag = DisconnectFlag()
        await device.setTestDisconnectHandler { _ in
            Task { @MainActor in flag.fired = true }
        }

        guard let accel = await device.makeAccelerometer(odrHz: 50, rangeG: 8) else {
            throw MWError.operationFailed("No accelerometer on this board")
        }

        @MainActor
        func run<S: MWStreamable>(_ sensor: S) async throws {
            let stream = try await device.startStream(sensor)
            var received = 0
            var streamEnded = false

            let consumer = Task { @MainActor in
                do {
                    for try await _ in stream {
                        received += 1
                        if received == 5 {
                            // A few real samples in hand — reboot the board
                            // out from under the stream.
                            try? await device.send(MWDebug.Reset())
                        }
                    }
                } catch { /* error termination is the expected path */ }
                streamEnded = true
            }

            let deadline = ContinuousClock.now + .seconds(15)
            while !streamEnded, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            consumer.cancel()

            print("  received \(received) samples before reset; streamEnded=\(streamEnded) callbackFired=\(flag.fired)")
            #expect(received >= 5, "Never reached the reset trigger — stream produced \(received) samples")
            #expect(streamEnded, "Sample stream did not terminate within 15 s of the reset")
            #expect(flag.fired, "onUnexpectedDisconnect did not fire")
            let state = await device.state
            #expect(state == .disconnected, "Device state is \(state), expected .disconnected")
        }

        switch accel {
        case .bmi160(let s): try await run(s)
        case .bmi270(let s): try await run(s)
        }
        // Board is rebooting — give it a moment to come back up so any
        // subsequently-run suite's scan finds it advertising again.
        try? await Task.sleep(for: .seconds(3))
    }
}
