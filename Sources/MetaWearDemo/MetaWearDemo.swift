import Foundation
import MetaWear

enum MetaWearDemo {

    @MainActor
    static func run() async throws {
        print("MetaWear BLE Demo")
        print("=================")
        print("Make sure Bluetooth is on and your MetaWear is nearby.\n")

        // MARK: - Scan

        let scanner = MetaWearScanner()
        print("Scanning for 8 seconds…")
        scanner.startScan()

        try await Task.sleep(for: .seconds(8))
        scanner.stopScan()

        let devices = scanner.discoveredDevices
        guard !devices.isEmpty else {
            print("No MetaWear devices found. Exiting.")
            return
        }

        print("Found \(devices.count) device(s):")
        for (_, device) in devices {
            let id = await device.identifier
            print("  • \(id)")
        }

        // Pick the first device
        guard let device = devices.values.first else { return }
        let deviceID = await device.identifier
        print("\nConnecting to \(deviceID)…")

        // MARK: - Connect

        try await device.connect()
        print("Connected.\n")

        // MARK: - Device info

        if let info = await device.deviceInfo {
            print("Device Info")
            print("  Manufacturer: \(info.manufacturer)")
            print("  Model:        \(info.modelNumber)")
            print("  Serial:       \(info.serialNumber)")
            print("  Firmware:     \(info.firmwareRevision)")
            print("  Hardware:     \(info.hardwareRevision)")
        }

        // MARK: - Battery

        let battery = try await device.readBattery()
        print("\nBattery: \(battery.charge)%  (\(battery.voltage) mV)")

        // MARK: - LED flash (green, 3 pulses)

        print("\nFlashing green LED…")
        try await device.send(MWLED.SetPattern(color: .green, .flash))
        try await device.send(MWLED.Play())
        try await Task.sleep(for: .seconds(2))
        try await device.send(MWLED.Stop())
        print("LED done.")

        // MARK: - Haptic pulse

        print("\nHaptic pulse…")
        try await device.send(MWHaptic.motor(dutyCycle: 80, pulseWidth: 300))

        // MARK: - Accelerometer stream (5 seconds, print every 20th sample)

        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        print("\nStreaming accelerometer at 100 Hz for 5 seconds…")
        print("  (printing every 20th sample)")

        let stream = try await device.startStream(sensor, usePacked: true)

        let deadline = Date.now.addingTimeInterval(5)
        var count = 0
        for try await sample in stream {
            count += 1
            if count % 20 == 0 {
                let v = sample.value
                print(String(format: "  [%5d]  x=%+.3f  y=%+.3f  z=%+.3f g", count, v.x, v.y, v.z))
            }
            if Date.now >= deadline { break }
        }

        try await device.stopStreaming(sensor)
        print("Stream stopped. Received \(count) samples in 5 s (~\(count/5) Hz).\n")

        // MARK: - Disconnect

        try await device.disconnect()
        print("Disconnected. Demo complete.")
    }
}
