import Testing
import MetaWear
import Darwin

@Suite("Hardware — Sensor Streaming", .serialized)
struct SensorStreamTests {

    // MARK: - Accelerometer (BMI160)

    @Test @MainActor
    func accelerometer_bmi160_receives1000Samples() async throws {
        try await withConnectedDevice { device in
            guard let impl = await device.moduleInfo(for: .accelerometer)?.implementation, impl == 1 || impl == 4 else {
                print("\n  Skipping — BMI not present\n"); return
            }
            let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
            let stream = try await device.stream(sensor, usePacked: true)

            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream {
                    samples.append(s.value)
                    fputs("  accel x=\(s.value.x) y=\(s.value.y) z=\(s.value.z)\n", stderr)
                }
            }

            try await Task.sleep(for: .seconds(20))
            collector.cancel()
            try await device.stopStreaming(sensor)

            // 100 Hz × 20 s = ~2000 samples; accept ≥ 1000 for BLE jitter
            #expect(samples.count > 1000,
                    "Expected ~2000 samples in 20 s at 100 Hz, got \(samples.count)")

            if let last = samples.last {
                let mag = (last.x * last.x + last.y * last.y + last.z * last.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Magnitude should be ~1 g at rest, got \(mag)")
                print("\n  Accelerometer BMI160: \(samples.count) samples, last=(x:\(last.x) y:\(last.y) z:\(last.z))\n")
            }
        }
    }

    @Test @MainActor
    func accelerometer_bmi160_duplicateStream_throws() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
                print("\n  Skipping — BMI160 not present\n"); return
            }
            let s1 = MWAccelerometerBMI160(odr: .hz100, range: .g2)
            let s2 = MWAccelerometerBMI160(odr: .hz50, range: .g4)
            _ = try await device.stream(s1, usePacked: false)
            defer { Task { try? await device.stopStreaming(s1) } }

            do {
                _ = try await device.stream(s2, usePacked: false)
                Issue.record("Should have thrown invalidState for duplicate accelerometer stream")
            } catch MWError.invalidState {
                // Expected
            }
        }
    }

    // MARK: - Accelerometer (BMI270)

    @Test @MainActor
    func accelerometer_bmi270_receives1000Samples() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            let stream = try await device.stream(sensor, usePacked: true)

            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream {
                    samples.append(s.value)
                    fputs("  accel x=\(s.value.x) y=\(s.value.y) z=\(s.value.z)\n", stderr)
                }
            }

            try await Task.sleep(for: .seconds(20))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 1000,
                    "Expected ~2000 samples in 20 s at 100 Hz, got \(samples.count)")

            if let last = samples.last {
                let mag = (last.x * last.x + last.y * last.y + last.z * last.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Magnitude should be ~1 g at rest, got \(mag)")
                print("\n  Accelerometer BMI270: \(samples.count) samples, last=(x:\(last.x) y:\(last.y) z:\(last.z))\n")
            }
        }
    }

    // MARK: - Gyroscope (BMI160)

    @Test @MainActor
    func gyroscope_bmi160_receivesData() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
                print("\n  Skipping — BMI160 not present\n"); return
            }
            let gyro = MWGyroscopeBMI160(odr: .hz50, range: .dps500)
            let stream = try await device.stream(gyro, usePacked: false)

            var count = 0
            let collector = Task {
                for try await _ in stream { count += 1 }
            }

            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(gyro)

            #expect(count > 50, "Expected ~100 gyro samples in 2 s at 50 Hz, got \(count)")
            print("\n  Gyroscope BMI160: \(count) samples in 2 s (~\(count / 2) Hz)\n")
        }
    }

    // MARK: - Gyroscope (BMI270)

    @Test @MainActor
    func gyroscope_bmi270_receivesData() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let gyro = MWGyroscopeBMI270(odr: .hz50, range: .dps500)
            let stream = try await device.stream(gyro, usePacked: false)

            var count = 0
            let collector = Task {
                for try await _ in stream { count += 1 }
            }

            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(gyro)

            #expect(count > 50, "Expected ~100 gyro samples in 2 s at 50 Hz, got \(count)")
            print("\n  Gyroscope BMI270: \(count) samples in 2 s (~\(count / 2) Hz)\n")
        }
    }

    // MARK: - Switch

    @Test @MainActor
    func switch_streamStarts_withoutError() async throws {
        try await withConnectedDevice { device in
            let stream = try await device.stream(MWSwitch())
            let collector = Task {
                for try await _ in stream { break }
            }
            try await Task.sleep(for: .seconds(1))
            collector.cancel()
            try await device.stopStreaming(MWSwitch())
            print("\n  Switch stream started and stopped without error\n")
        }
    }
}
