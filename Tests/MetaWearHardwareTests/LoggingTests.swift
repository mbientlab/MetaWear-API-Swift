import Testing
import MetaWear

// MARK: - Helpers

/// Consume a download stream to completion, returning the final batch of samples.
private func collectLog<Sample: Sendable>(
    _ stream: AsyncThrowingStream<Download<[MWLoggedSample<Sample>]>, Error>
) async throws -> [MWLoggedSample<Sample>] {
    var latest: [MWLoggedSample<Sample>] = []
    for try await progress in stream {
        latest = progress.data
    }
    return latest
}

// MARK: - Tests

@Suite("Hardware — Logging", .serialized)
struct LoggingTests {

    @Test @MainActor
    func logging_accelerometer_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
                print("\n  Skipping — BMI160 not present\n"); return
            }
            let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(3))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 50,
                    "Expected ≥ 50 samples in 3 s at 50 Hz, got \(entries.count)")

            if let last = entries.last {
                let v = last.value
                let mag = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Sample magnitude should be ~1 g at rest, got \(mag)")
            }

            try await device.clearLog()

            print("\n  Logging: \(entries.count) accelerometer samples downloaded\n")
            if let first = entries.first, let last = entries.last {
                let span = last.date.timeIntervalSince(first.date)
                print("  Log span: \(String(format: "%.2f", span)) s  " +
                      "(~\(Int(Double(entries.count) / max(span, 1))) Hz)\n")
            }
        }
    }

    @Test @MainActor
    func logging_gyroscope_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
                print("\n  Skipping — BMI160 not present\n"); return
            }
            let sensor = MWGyroscopeBMI160(odr: .hz50, range: .dps500)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(2))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 30,
                    "Expected ≥ 30 gyro samples in 2 s at 50 Hz, got \(entries.count)")

            try await device.clearLog()
            print("\n  Logging: \(entries.count) gyroscope samples downloaded\n")
        }
    }

    @Test @MainActor
    func logging_clearLog_removesEntries() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
                print("\n  Skipping — BMI160 not present\n"); return
            }
            let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(1))
            try await device.stopLogging(sensor)
            try await device.clearLog()

            // After clear, re-register logger to allow download attempt
            try await device.startLogging(sensor)
            try await device.stopLogging(sensor)
            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count < 10,
                    "After clearLog, download should return ~0 samples, got \(entries.count)")
            try await device.clearLog()
        }
    }

    // MARK: - BMI270

    @Test @MainActor
    func logging_accelerometer_bmi270_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(3))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 50,
                    "Expected ≥ 50 samples in 3 s at 50 Hz, got \(entries.count)")

            if let last = entries.last {
                let v = last.value
                let mag = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Sample magnitude should be ~1 g at rest, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Logging BMI270: \(entries.count) accelerometer samples downloaded\n")
        }
    }

    @Test @MainActor
    func logging_gyroscope_bmi270_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWGyroscopeBMI270(odr: .hz50, range: .dps500)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(2))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 30,
                    "Expected ≥ 30 gyro samples in 2 s at 50 Hz, got \(entries.count)")

            try await device.clearLog()
            print("\n  Logging BMI270: \(entries.count) gyroscope samples downloaded\n")
        }
    }

    // MARK: - Raw (untyped) download

    @Test @MainActor
    func logging_rawDownload_returnsEntries() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
                print("\n  Skipping — BMI160 not present\n"); return
            }
            let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(2))  // ~100 samples at 50 Hz
            try await device.stopLogging(sensor)

            // Raw download — untyped, returns RawLogEntry
            let stream = try await device.downloadLogs()
            var allEntries: [RawLogEntry] = []
            for try await progress in stream {
                allEntries = progress.data
            }

            #expect(allEntries.count > 0, "Raw download should return at least one entry")

            if let first = allEntries.first {
                // Each entry covers one 4-byte chunk; 50 Hz × 2 s × 2 chunks/sample = ~200 entries
                #expect(first.epochMs >= 0, "epochMs should be non-negative")
                print("\n  Raw download: \(allEntries.count) entries, " +
                      "first tick=\(first.tick) epochMs=\(String(format: "%.1f", first.epochMs))\n")
            }

            try await device.clearLog()
        }
    }

    // MARK: - Logger recovery after reconnect

    @Test @MainActor
    func logging_recoverLoggers_afterReconnect() async throws {
        // Phase 1: start logging, stop, disconnect (without clearing)
        let device = try await nearbyDevice()
        try await device.connect()

        guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
            print("\n  Skipping — BMI160 not present\n")
            try await device.disconnect()
            return
        }

        let sensor = MWAccelerometerBMI160(odr: .hz25, range: .g2)
        try await device.startLogging(sensor)
        try await Task.sleep(for: .seconds(2))  // ~50 samples at 25 Hz
        try await device.stopLogging(sensor)
        // Disconnect without clearing — loggers remain active on the board
        try await device.disconnect()

        // Phase 2: reconnect, recover loggers, download
        try await Task.sleep(for: .seconds(1))  // let the board re-advertise
        try await device.connect()
        try await device.recoverLoggers(for: sensor)

        let stream = try await device.downloadLogs(sensor)
        var entries: [MWLoggedSample<CartesianFloat>] = []
        for try await progress in stream {
            entries = progress.data
        }

        #expect(entries.count > 20,
                "Expected ≥ 20 recovered samples after reconnect, got \(entries.count)")

        try await device.clearLog()
        try await device.disconnect()

        print("\n  Logger recovery: \(entries.count) samples recovered after reconnect\n")
    }
}
