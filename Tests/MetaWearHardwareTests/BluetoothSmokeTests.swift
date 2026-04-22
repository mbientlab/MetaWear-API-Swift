import Testing
import CoreBluetooth

@Suite("Bluetooth — Smoke")
struct BluetoothSmokeTests {

    @Test func bluetooth_isPoweredOn() async throws {
        let queue = DispatchQueue(label: "bt-test")
        let central = CBCentralManager(delegate: nil, queue: queue)

        try await Task.sleep(for: .seconds(2))

        fputs("BT state raw value: \(central.state.rawValue)\n", stderr)
        #expect(central.state == .poweredOn, "Expected poweredOn, got \(central.state.rawValue)")
    }
}
