@preconcurrency import CoreBluetooth
import Foundation

/// In-memory BLE transport for unit tests. No hardware required.
public actor MockBLETransport: BLETransport {

    public var connectError: Error?
    public var disconnectError: Error?
    public var readResponses: [CBUUID: Data] = [:]
    public var writtenData: [(Data, CBUUID, CBCharacteristicWriteType)] = []
    /// Optional artificial delay injected at the start of `connect()`.
    /// Set this before calling `connect()` to widen the window for tests
    /// that need to observe an in-progress connection (e.g. `.connecting` state).
    public var connectDelay: Duration = .zero

    private var notifyContinuations: [CBUUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    public init() {}

    public func scan(for services: [CBUUID]?) -> AsyncStream<ScanResult> {
        AsyncStream { _ in }
    }

    public func connect(to identifier: UUID) async throws {
        if connectDelay > .zero { try await Task.sleep(for: connectDelay) }
        if let error = connectError { throw error }
    }

    public func disconnect() async throws {
        if let error = disconnectError { throw error }
        notifyContinuations.values.forEach { $0.finish() }
        notifyContinuations.removeAll()
    }

    public func write(_ data: Data, to characteristic: CBUUID, type: CBCharacteristicWriteType) async throws {
        writtenData.append((data, characteristic, type))
    }

    public func read(from characteristic: CBUUID) async throws -> Data {
        guard let data = readResponses[characteristic] else {
            throw MWError.operationFailed("No mock response for \(characteristic)")
        }
        return data
    }

    public func notifications(from characteristic: CBUUID) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        notifyContinuations[characteristic] = continuation
        return stream
    }

    /// Mock RSSI reading — returns `mockRSSI` (default -55 dBm). Set
    /// `mockRSSI` in tests to simulate different signal strengths.
    public var mockRSSI: Int = -55
    public func readRSSI() async throws -> Int { mockRSSI }

    /// Configure errors for testing — call before connect/disconnect.
    public func setConnectError(_ error: Error?) { connectError = error }
    public func setDisconnectError(_ error: Error?) { disconnectError = error }
    public func setConnectDelay(_ delay: Duration) { connectDelay = delay }

    /// Returns only the `Data` payloads from all write calls (CBUUID is not Sendable).
    public var writtenCommands: [Data] { writtenData.map(\.0) }

    /// Inject a notification packet — call this from test code to simulate MetaWear responses.
    public func inject(notification: Data, to characteristic: CBUUID) {
        notifyContinuations[characteristic]?.yield(notification)
    }

    /// Simulate a BLE disconnect mid-stream.
    public func simulateDisconnect(error: Error? = nil) {
        let err = error ?? MWError.operationFailed("Simulated disconnect")
        notifyContinuations.values.forEach { $0.finish(throwing: err) }
        notifyContinuations.removeAll()
    }
}
