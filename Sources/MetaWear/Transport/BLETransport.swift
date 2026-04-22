@preconcurrency import CoreBluetooth
import Foundation

// MARK: - Scan result

public struct ScanResult: Sendable {
    public let identifier: UUID
    public let name: String?
    public let rssi: Int
}

// MARK: - BLE Transport protocol

/// Platform-agnostic BLE interface. Swap CoreBluetoothTransport for MockBLETransport in tests.
public protocol BLETransport: Actor {
    /// Scan for MetaWear peripherals. Cancel the enclosing Task to stop scanning.
    func scan(for services: [CBUUID]?) -> AsyncStream<ScanResult>

    /// Connect to a peripheral by UUID. Throws if connection fails or times out.
    func connect(to identifier: UUID) async throws

    /// Disconnect the current peripheral.
    func disconnect() async throws

    /// Write data to a characteristic.
    func write(_ data: Data, to characteristic: CBUUID, type: CBCharacteristicWriteType) async throws

    /// Perform a one-shot read from a characteristic.
    func read(from characteristic: CBUUID) async throws -> Data

    /// Subscribe to notifications from a characteristic.
    /// The stream terminates with an error on BLE disconnect.
    func notifications(from characteristic: CBUUID) -> AsyncThrowingStream<Data, Error>
}
