import Testing
import Foundation
import MetaWear

@Suite("Hardware — Settings", .serialized)
struct SettingsTests {

    // MARK: - Settings

    @Test @MainActor
    func settings_setAndRestoreDeviceName() async throws {
        let device = try await nearbyDevice()
        let uuid = device.identifier

        // Capture the original advertised name so we can restore it.
        try await device.connect()
        try await Task.sleep(for: .seconds(5))
        try await device.disconnect()
        try await Task.sleep(for: .seconds(5))
        guard let originalName = try await awaitAdvertisedName(for: uuid) else {
            Issue.record("Could not observe baseline advertised name")
            return
        }
        print("\n\n  Advertised name (baseline): \"\(originalName)\"\n")

        // --- Set "MWTest" and verify via rescan --------------------------------
        try await device.connect()
        try await device.send(MWSettings.SetDeviceName("MWTest"))
        try await Task.sleep(for: .seconds(5))
        try await device.disconnect()
        try await Task.sleep(for: .seconds(5))

        let afterSet = try await awaitAdvertisedName(for: uuid)
        print("\n  Advertised name (after set):     \"\(afterSet ?? "<timeout>")\"\n")
        #expect(afterSet == "MWTest",
                "Expected \"MWTest\" in advertisement, got \"\(afterSet ?? "<timeout>")\"")

        // --- Restore the original name and verify ------------------------------
        let restoreName = String(originalName.prefix(MWSettings.maxDeviceNameLength))
        try await device.connect()
        try await device.send(MWSettings.SetDeviceName(restoreName))
        try await Task.sleep(for: .seconds(5))
        try await device.disconnect()
        try await Task.sleep(for: .seconds(5))

        let afterRestore = try await awaitAdvertisedName(for: uuid)
        print("\n  Advertised name (after restore): \"\(afterRestore ?? "<timeout>")\"\n")
        #expect(afterRestore == restoreName,
                "Expected \"\(restoreName)\" in advertisement, got \"\(afterRestore ?? "<timeout>")\"")
    }

    @Test @MainActor
    func settings_setTXPower_doesNotThrow() async throws {
        try await withConnectedDevice { device in
            // Baseline at 0 dBm. Single-shot RSSI varies by ±5–10 dB even at
            // rest, so take several samples and average for a stable reading.
            try await device.send(MWSettings.SetTXPower(.zero))
            try await Task.sleep(for: .seconds(3))   // let the radio apply the new power level
            let baseline = try await sampleRSSI(device, count: 8)
            try await Task.sleep(for: .seconds(3))
            
            // Boost to +4 dBm and measure again — expect a higher (less-negative) RSSI.
            try await device.send(MWSettings.SetTXPower(.plus4))
            try await Task.sleep(for: .seconds(3))
            let boosted  = try await sampleRSSI(device, count: 8)
            try await Task.sleep(for: .seconds(3))
            
            print("\n  TX power  0 dBm: avg RSSI = \(String(format: "%.1f", baseline)) dBm")
            print("  TX power +4 dBm: avg RSSI = \(String(format: "%.1f", boosted)) dBm")
            print("  Δ = \(String(format: "%+.1f", boosted - baseline)) dB (expected ~+4)\n")

            #expect(boosted > baseline,
                    "Expected +4 dBm RSSI (\(boosted)) to exceed 0 dBm baseline (\(baseline))")
        }
    }

    /// Averaged RSSI sample — single readings are noisy (±5-10 dB at rest) so
    /// we take `count` readings spaced ~100 ms apart and return the mean.
    private func sampleRSSI(_ device: MetaWearDevice, count: Int) async throws -> Double {
        var total = 0
        for _ in 0..<count {
            total += try await device.readRSSI()
            try await Task.sleep(for: .milliseconds(100))
        }
        return Double(total) / Double(count)
    }

    @Test @MainActor
    func settings_setConnectionParameters_lowLatency() async throws {
        // CoreBluetooth does not expose the negotiated connection interval, so
        // we verify the change indirectly by timing BLE round-trips. A write+
        // notify cycle needs ~2 connection events, so at `balanced` (30 ms
        // interval) expect ~60 ms avg; at `lowLatency` (7.5 ms) expect ~15-20 ms.
        try await withConnectedDevice { device in
            // --- Balanced baseline ------------------------------------------
            try await device.send(MWSettings.SetConnectionParameters.balanced)
            try await Task.sleep(for: .seconds(3))    // let iOS renegotiate
            let balancedMs = try await averageRoundTripMs(device, count: 10)
            try await Task.sleep(for: .seconds(3))
            
            // --- Switch to low latency and re-measure ----------------------
            try await device.send(MWSettings.SetConnectionParameters.lowLatency)
            try await Task.sleep(for: .seconds(3))
            let lowLatencyMs = try await averageRoundTripMs(device, count: 10)
            try await Task.sleep(for: .seconds(3))
            
            print("\n  Round-trip avg (balanced, 30 ms interval):    \(String(format: "%.1f", balancedMs)) ms")
            print("  Round-trip avg (lowLatency, 7.5 ms interval): \(String(format: "%.1f", lowLatencyMs)) ms")
            print("  Δ = \(String(format: "%+.1f", lowLatencyMs - balancedMs)) ms " +
                  "(lowLatency should be ~40 ms faster if iOS honored the 7.5 ms request)\n")

            // Allow for iOS sometimes clamping the minimum interval to 15 ms
            // (it doesn't always honor 7.5 ms). A clear improvement is expected
            // regardless — anything less than a 20% reduction is suspicious.
            #expect(lowLatencyMs < balancedMs * 0.8,
                    "Expected lowLatency round-trip (\(lowLatencyMs) ms) to be noticeably faster than balanced (\(balancedMs) ms)")

            // Restore balanced before disconnect.
            try await device.send(MWSettings.SetConnectionParameters.balanced)
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// Measure the average BLE round-trip time in milliseconds by issuing
    /// `count` one-shot battery reads back-to-back and averaging their
    /// elapsed times. Each read is a write+notify cycle that costs ~2
    /// connection events, so the measurement directly reflects the current
    /// connection interval.
    private func averageRoundTripMs(_ device: MetaWearDevice, count: Int) async throws -> Double {
        let clock = ContinuousClock()
        var totalNanos: UInt64 = 0
        for _ in 0..<count {
            let start = clock.now
            _ = try await device.readBattery()
            let elapsed = clock.now - start
            totalNanos += UInt64(elapsed.components.seconds) * 1_000_000_000
                        + UInt64(elapsed.components.attoseconds / 1_000_000_000)
        }
        return Double(totalNanos) / Double(count) / 1_000_000.0   // ns → ms
    }

    @Test @MainActor
    func settings_startAdvertising_doesNotThrow() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWSettings.StartAdvertising())
            print("\n  ✓ StartAdvertising sent without error\n")
        }
    }
}
