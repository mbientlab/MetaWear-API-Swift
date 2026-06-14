@preconcurrency import CoreBluetooth
import Foundation

// MARK: - Scan result

/// One CoreBluetooth advertisement normalized for the SDK scanner.
public struct ScanResult: Sendable {
    /// Stable CoreBluetooth identifier for the advertising peripheral.
    public let identifier: UUID
    /// Advertised local name, if present in the packet.
    public let name: String?
    /// Received signal strength in dBm for this advertisement.
    public let rssi: Int
    /// Raw bytes from `CBAdvertisementDataManufacturerDataKey`, if present.
    /// For iBeacon advertisements this is the full manufacturer-specific payload
    /// beginning with the Apple company ID (`0x4C 0x00`) followed by the iBeacon
    /// sub-type byte (`0x02`), length (`0x15`), 16-byte UUID, 2-byte major, 2-byte
    /// minor, and 1-byte measured-RSSI reference.
    public let manufacturerData: Data?
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

    /// Read the current RSSI of the active connection, in dBm. Requires an
    /// established connection. Larger values (i.e. closer to zero) indicate a
    /// stronger received signal at the central.
    func readRSSI() async throws -> Int
}
