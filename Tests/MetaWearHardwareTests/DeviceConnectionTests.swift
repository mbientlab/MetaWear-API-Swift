import Testing
import MetaWear
import Foundation

// MARK: - Hardware tests for connect / disconnect lifecycle

@Suite("Hardware — Device Connection Lifecycle", .serialized)
struct DeviceConnectionTests {

    // MARK: - Helpers

    /// Make sure each test starts from `.disconnected`. Protects against
    /// ordering issues — `nearbyDevice()` caches one device across the suite,
    /// so a previously-failing test could leave it connected.
    @MainActor
    private func ensureDisconnected(_ device: MetaWearDevice) async throws {
        let state = await device.state
        if state != .disconnected {
            try? await device.disconnect()
        }
    }

    // MARK: - test_Connects_Once

    /// Connect once and assert the device settles on `.idle` and stays
    /// there. The legacy variant verifies no spurious extra transitions on
    /// the publisher; we check the same property by polling `state` for a
    /// short window after the connect returns.
    @Test @MainActor
    func connect_reachesIdleStateOnce() async throws {
        let device = try await nearbyDevice()
        try await ensureDisconnected(device)

        let initial = await device.state
        #expect(initial == .disconnected,
                "Initial state must be .disconnected, got \(initial)")

        try await device.connect()

        let connected = await device.state
        #expect(connected == .idle,
                "State must be .idle immediately after connect(), got \(connected)")

        let info = await device.deviceInfo
        #expect(info != nil, "deviceInfo must be populated after connect()")

        // No spurious transitions: state should remain `.idle` over a short
        // observation window. Without a state-change stream, polling is the
        // best we can do — 500 ms is generous enough to catch a regression
        // that would re-disconnect the board after a successful connect.
        try await Task.sleep(for: .milliseconds(500))
        let later = await device.state
        #expect(later == .idle,
                "State must stay .idle for at least 500 ms after connect(), got \(later)")

        try await device.disconnect()
        print("\n  ✓ connect_reachesIdleStateOnce\n")
    }

    // MARK: - test_Disconnect_WhenConnected

    /// Connect to `.idle`, then disconnect to `.disconnected`. The legacy
    /// variant verifies all five transition events on the publisher; we
    /// verify the two endpoints of the cycle that our state model exposes.
    @Test @MainActor
    func disconnect_whenConnected_returnsToDisconnected() async throws {
        let device = try await nearbyDevice()
        try await ensureDisconnected(device)

        try await device.connect()
        let connected = await device.state
        #expect(connected == .idle, "Expected .idle after connect, got \(connected)")

        try await device.disconnect()
        let disconnected = await device.state
        #expect(disconnected == .disconnected,
                "Expected .disconnected after disconnect, got \(disconnected)")

        print("\n  ✓ disconnect_whenConnected_returnsToDisconnected\n")
    }
}
