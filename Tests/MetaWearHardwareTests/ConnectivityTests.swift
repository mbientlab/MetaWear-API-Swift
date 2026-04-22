import Testing
import MetaWear

@Suite("Hardware — Connectivity", .serialized)
struct ConnectivityTests {

    @Test @MainActor
    func deviceInfo_isPopulated() async throws {
        try await withConnectedDevice { device in
            let info = await device.deviceInfo
            #expect(info != nil, "deviceInfo must be populated after connect()")
            guard let info else { return }

            print("""

            ── Device Info ─────────────────────
              Manufacturer : \(info.manufacturer)
              Model        : \(info.modelNumber)
              Serial       : \(info.serialNumber)
              Firmware     : \(info.firmwareRevision)
              Hardware     : \(info.hardwareRevision)
            ────────────────────────────────────\n
            """)

            #expect(!info.manufacturer.isEmpty)
            #expect(!info.modelNumber.isEmpty)
            #expect(!info.serialNumber.isEmpty)
            #expect(!info.firmwareRevision.isEmpty)
            #expect(!info.hardwareRevision.isEmpty)
        }
    }

    @Test @MainActor
    func battery_returnsReasonableValues() async throws {
        try await withConnectedDevice { device in
            let battery = try await device.readBattery()
            
            print("\n  Battery: \(battery.charge) %  (\(battery.voltage) mV)\n")
            
            #expect(battery.charge >= 0)
            #expect(battery.charge <= 100)
            #expect(battery.voltage > 0)
        }
    }

    @Test @MainActor
    func accelerometerModule_isPresent() async throws {
        try await withConnectedDevice { device in
            let info = await device.moduleInfo(for: .accelerometer)
            
            print("\n  Accelerometer is present: \(info?.isPresent, default: "false")\n")
            
            #expect(info != nil)
            #expect(info?.isPresent == true)
        }
    }

    @Test @MainActor
    func makeAccelerometer_returnsCorrectType() async throws {
        try await withConnectedDevice { device in
            let acc = await device.makeAccelerometer(odrHz: 100, rangeG: 2)
            #expect(acc != nil, "makeAccelerometer should return a value when module is present")

            let impl = await device.moduleInfo(for: .accelerometer)?.implementation
            
            print("\n  makeAccelerometer: \(acc != nil ? "got value" : "nil") impl=\(impl ?? 0xFF)\n")
            
            switch acc {
            case .bmi160:
                #expect(impl == 1, "Expected impl=1 for BMI160, got \(impl ?? 0xFF)")
            case .bmi270:
                #expect(impl == 4, "Expected impl=4 for BMI270, got \(impl ?? 0xFF)")
            case nil:
                Issue.record("makeAccelerometer returned nil with module present")
            }
        }
    }

    @Test @MainActor
    func reconnect_succeedsAfterDisconnect() async throws {
        let device = try await nearbyDevice()
        try await device.connect()
        print("\n  connect \n")
        
        try await device.disconnect()
        print("\n  disconnect \n")
        
        // Device re-advertises after ~1 s
        try await Task.sleep(for: .seconds(2))
        try await device.connect()
        print("\n  connect \n")
        
        let info = await device.deviceInfo
        #expect(info != nil, "deviceInfo must be populated after reconnect")

        try await device.disconnect()
        print("\n  disconnect \n")
    }
}
