import Testing
import MetaWear
import Foundation

// MARK: - Helpers (file-scope)

/// Compare dot-separated numeric version strings. Treats missing components
/// as zero, so `"1.5"` and `"1.5.0"` are equal and `"1.10.0" > "1.9.99"`.
/// Used by `firmwareVersion_isAtLeast_1_5_0`.
private func versionAtLeast(_ version: String, minimum: String) -> Bool {
    let v = version.split(separator: ".").compactMap { Int($0) }
    let m = minimum.split(separator: ".").compactMap { Int($0) }
    let n = max(v.count, m.count)
    for i in 0..<n {
        let a = i < v.count ? v[i] : 0
        let b = i < m.count ? m[i] : 0
        if a > b { return true }
        if a < b { return false }
    }
    return true
}

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

    /// Connect, then dump everything `connect()` discovered about the board:
    /// device info, plus every module the firmware reported back during the
    /// initial `[module, 0x80]` round-trip — implementation/revision/extra
    /// bytes per module, with a present/absent indicator.
    ///
    /// Useful for diagnosing "is this a BMI160 or BMI270 board?", inspecting
    /// the multi-channel temperature map, or verifying that custom firmware
    /// reports the modules it should.
    @Test @MainActor
    func deviceInfo_andAllModules_arePopulated() async throws {
        try await withConnectedDevice { device in
            let info    = await device.deviceInfo
            let modules = await device.modules
            #expect(info != nil, "deviceInfo must be populated after connect()")
            guard let info else { return }

            // MAC address lives on Settings module register 0x0B; on iOS
            // it's the only way to get the real MAC since CoreBluetooth
            // hands us a CBUUID instead of the hardware address.
            let mac = try await device.read(MWMACAddress()).value

            // Header: device info, same as deviceInfo_isPopulated() plus MAC
            // and the resolved board model (MMS / MMRL / unknown).
            print("""

            ── Device Info ─────────────────────
              Manufacturer : \(info.manufacturer)
              Model        : \(info.modelNumber)
              Board        : \(info.model.name)
              Serial       : \(info.serialNumber)
              MAC          : \(mac)
              Firmware     : \(info.firmwareRevision)
              Hardware     : \(info.hardwareRevision)
            ────────────────────────────────────
            """)

            // The SDK only supports MMRL and MMS — anything else is a board
            // we haven't validated against, and the assertion below will fail
            // loudly so the operator knows.
            #expect(info.model == .motionRL || info.model == .motionS,
                    "Unsupported board model: \(info.model.name)")

            // MAC must look like "XX:XX:XX:XX:XX:XX" — six hex pairs.
            let macParts = mac.split(separator: ":")
            #expect(macParts.count == 6, "MAC has wrong number of segments: \(mac)")
            #expect(macParts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) },
                    "MAC segments are not 2-char hex: \(mac)")

            // Per-module table. Walk in opcode order so the output is
            // deterministic and easy to diff between boards.
            print("── Modules ─────────────────────────")
            print("  opcode  module          present  impl  rev   extra")
            print("  ──────  ──────────────  ───────  ────  ───   ───────────────")

            var present = 0, absent = 0
            for module in MWModule.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let m = modules[module] else {
                    // Module not in the discovery map at all (firmware never
                    // responded for this opcode).
                    let opcode = String(format: "0x%02X", module.rawValue)
                    let name = module.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                    print("  \(opcode)    \(name)  (no reply)")
                    continue
                }
                let opcode = String(format: "0x%02X", m.module.rawValue)
                let name   = m.module.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                let pres   = m.isPresent ? "yes    " : "no     "
                let impl   = String(format: "0x%02X", m.implementation)
                let rev    = String(format: "0x%02X", m.revision)
                let extra  = m.extra.isEmpty
                    ? "—"
                    : m.extra.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("  \(opcode)    \(name)  \(pres)  \(impl)  \(rev)  \(extra)")
                if m.isPresent { present += 1 } else { absent += 1 }
            }
            print("────────────────────────────────────")
            print("  Total: \(present) present, \(absent) absent\n")

            // Sanity assertions — at least the always-present modules should
            // be there on any healthy board (LED, settings, debug, logging).
            #expect(modules[.led]?.isPresent      == true, "LED module missing")
            #expect(modules[.settings]?.isPresent == true, "Settings module missing")
            #expect(modules[.debug]?.isPresent    == true, "Debug module missing")
            #expect(modules[.logging]?.isPresent  == true, "Logging module missing")
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
            
            print("\n  Accelerometer is present: \(info?.isPresent ?? false)\n")
            
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

    // MARK: - Advertised name
    //
    // The board's advertised local name should be present and pass the same
    // validity rules a rename would (`MWSettings.isNameValid`). This catches
    // boards that came back from a partial provisioning failure with garbage
    // names, as well as encoding regressions in our advertisement parser.

    @Test @MainActor
    func advertisedName_isPresentAndValid() async throws {
        // Make sure the scanner cache is populated; this is also what
        // `awaitAdvertisedName` requires. Subsequent tests reuse it.
        let device = try await nearbyDevice()
        let uuid   = device.identifier

        guard let name = try await awaitAdvertisedName(for: uuid, timeout: .seconds(5)) else {
            Issue.record("Did not observe an advertised name within 5 s for \(uuid)")
            return
        }

        print("\n  Advertised name: \"\(name)\"\n")

        #expect(!name.isEmpty, "Advertised name must not be empty")
        #expect(MWSettings.isNameValid(name),
                "Advertised name failed isNameValid (length / charset): \"\(name)\"")
    }

    // MARK: - Firmware floor
    //
    // Tests a minimum firmware

    @Test @MainActor
    func firmwareVersion_isAtLeast_1_5_0() async throws {
        try await withConnectedDevice { device in
            guard let info = await device.deviceInfo else {
                Issue.record("deviceInfo nil after connect()"); return
            }
            let firmware = info.firmwareRevision
            print("\n  Firmware: \(firmware) (minimum 1.5.0)\n")
            #expect(versionAtLeast(firmware, minimum: "1.5.0"),
                    "Firmware \(firmware) is older than the 1.5.0 minimum the SDK targets")
        }
    }

    // MARK: - Live RSSI
    //
    // Tests live RSSI data

    @Test @MainActor
    func rssi_canBeRead() async throws {
        try await withConnectedDevice { device in
            var rssis: [Int] = []
            for _ in 0..<3 {
                let r = try await device.readRSSI()
                rssis.append(r)
                try await Task.sleep(for: .milliseconds(250))
            }
            print("\n  RSSI samples: \(rssis.map { "\($0)" }.joined(separator: ", ")) dBm\n")

            for r in rssis {
                // Bluetooth RSSI is reported as a signed Int8; valid live values
                // are strictly negative and bounded below by −127 (the protocol
                // floor). 0 is the "unknown" placeholder some stacks return
                // when no measurement is available — treat that as a failure.
                #expect(r > -127 && r < 0,
                        "RSSI out of plausible range: \(r) dBm")
            }
        }
    }
}
