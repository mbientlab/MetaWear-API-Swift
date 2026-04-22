import Testing
import MetaWear

@Suite("Hardware — Sensor Fusion", .serialized)
struct SensorFusionTests {

    // MARK: - Quaternion

    @Test @MainActor
    func sensorFusion_quaternion_unitMagnitude() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            let sensor = MWSensorFusionQuaternion(mode: .imuPlus)
            let stream = try await device.stream(sensor)
            var samples: [Quaternion] = []
            let collector = Task {
                for try await s in stream { samples.append(s.value) }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 10, "Expected quaternion samples, got \(samples.count)")

            if let q = samples.last {
                let mag = (q.w*q.w + q.x*q.x + q.y*q.y + q.z*q.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.05,
                        "Unit quaternion magnitude should be ~1.0, got \(mag)")
                print("\n  Quaternion: \(samples.count) samples, " +
                      "last=(w:\(String(format:"%.3f",q.w)) x:\(String(format:"%.3f",q.x)) " +
                      "y:\(String(format:"%.3f",q.y)) z:\(String(format:"%.3f",q.z))) |q|=\(String(format:"%.4f",mag))\n")
            }
        }
    }

    // MARK: - Euler angles

    @Test @MainActor
    func sensorFusion_eulerAngles_plausibleRange() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            let sensor = MWSensorFusionEuler(mode: .imuPlus)
            let stream = try await device.stream(sensor)
            var samples: [EulerAngles] = []
            let collector = Task {
                for try await s in stream { samples.append(s.value) }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 10, "Expected Euler angle samples, got \(samples.count)")

            if let e = samples.last {
                #expect(e.heading >= 0 && e.heading <= 360,
                        "Heading should be 0–360°, got \(e.heading)")
                #expect(e.pitch >= -180 && e.pitch <= 180,
                        "Pitch should be ±180°, got \(e.pitch)")
                #expect(e.roll >= -90 && e.roll <= 90,
                        "Roll should be ±90°, got \(e.roll)")
                print("\n  Euler: \(samples.count) samples, " +
                      "last=(heading:\(String(format:"%.1f",e.heading))° " +
                      "pitch:\(String(format:"%.1f",e.pitch))° " +
                      "roll:\(String(format:"%.1f",e.roll))°)\n")
            }
        }
    }

    // MARK: - Gravity vector

    @Test @MainActor
    func sensorFusion_gravityVector_magnitudeNearOneG() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            let sensor = MWSensorFusionGravity(mode: .imuPlus)
            let stream = try await device.stream(sensor)
            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream { samples.append(s.value) }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 10, "Expected gravity vector samples, got \(samples.count)")

            if let g = samples.last {
                let mag = (g.x*g.x + g.y*g.y + g.z*g.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.2,
                        "Gravity magnitude should be ~1 g, got \(mag)")
                print("\n  Gravity: \(samples.count) samples, " +
                      "last=(x:\(String(format:"%.3f",g.x)) y:\(String(format:"%.3f",g.y)) " +
                      "z:\(String(format:"%.3f",g.z))) |g|=\(String(format:"%.4f",mag))\n")
            }
        }
    }

    // MARK: - Linear acceleration

    @Test @MainActor
    func sensorFusion_linearAcceleration_nearZeroAtRest() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            let sensor = MWSensorFusionLinearAcceleration(mode: .imuPlus)
            let stream = try await device.stream(sensor)
            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream { samples.append(s.value) }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 10, "Expected linear acceleration samples, got \(samples.count)")

            // At rest, linear acceleration (gravity-subtracted) should be ~0
            if !samples.isEmpty {
                let avgMag = samples.map { s -> Float in
                    (s.x*s.x + s.y*s.y + s.z*s.z).squareRoot()
                }.reduce(0, +) / Float(samples.count)

                #expect(Double(avgMag) < 0.3,
                        "Linear acceleration at rest should be ~0 g, average magnitude was \(avgMag)")
                print("\n  Linear acceleration: \(samples.count) samples, avg magnitude=\(String(format:"%.4f",avgMag)) g\n")
            }
        }
    }

    // MARK: - Calibration

    @Test @MainActor
    func sensorFusion_readCalibration_returnsPlausibleValues() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            // Start fusion so calibration is active
            let sensor = MWSensorFusionQuaternion(mode: .ndof)
            let stream = try await device.stream(sensor)
            let collector = Task { for try await _ in stream {} }
            defer { collector.cancel() }

            try await Task.sleep(for: .seconds(1))
            let cal = try await device.readFusionCalibration()

            // Each value must be 0–3
            #expect(cal.accelerometer <= 3, "Accel calibration out of range: \(cal.accelerometer)")
            #expect(cal.gyroscope     <= 3, "Gyro calibration out of range: \(cal.gyroscope)")
            #expect(cal.magnetometer  <= 3, "Mag calibration out of range: \(cal.magnetometer)")

            try await device.stopStreaming(sensor)
            print("\n  Calibration: accel=\(cal.accelerometer) gyro=\(cal.gyroscope) mag=\(cal.magnetometer)\n")
        }
    }

    // MARK: - Logging

    @Test @MainActor
    func sensorFusion_quaternion_logsAndDownloads() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            let sensor = MWSensorFusionQuaternion(mode: .imuPlus)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(3))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            var entries: [MWLoggedSample<Quaternion>] = []
            for try await progress in stream { entries = progress.data }

            #expect(entries.count > 10, "Expected quaternion log samples, got \(entries.count)")

            if let q = entries.last?.value {
                let mag = (q.w*q.w + q.x*q.x + q.y*q.y + q.z*q.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.1,
                        "Logged quaternion magnitude should be ~1, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Fusion logging: \(entries.count) quaternion samples downloaded\n")
        }
    }

    @Test @MainActor
    func sensorFusion_gravity_logsAndDownloads() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .sensorFusion)?.isPresent == true else {
                print("\n  Skipping sensor fusion — module not present\n")
                return
            }

            let sensor = MWSensorFusionGravity(mode: .imuPlus)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(3))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            var entries: [MWLoggedSample<CartesianFloat>] = []
            for try await progress in stream { entries = progress.data }

            #expect(entries.count > 10, "Expected gravity log samples, got \(entries.count)")

            if let g = entries.last?.value {
                let mag = (g.x*g.x + g.y*g.y + g.z*g.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.2,
                        "Logged gravity magnitude should be ~1 g, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Fusion logging: \(entries.count) gravity samples downloaded\n")
        }
    }
}
