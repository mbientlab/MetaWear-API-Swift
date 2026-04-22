import Testing
import MetaWear
import Foundation

// MARK: - Scan cache
//
// Scans once for the first 10 seconds; subsequent calls reuse the result.
// This means the whole suite only pays one scan-timeout, not one per test.

@MainActor private var _cachedDevice: MetaWearDevice? = nil
@MainActor private var _cachedScanner: MetaWearScanner? = nil   // keeps MWCentralManager alive
@MainActor private var _scanAttempted = false

/// Returns the first nearby MetaWear device, or throws if none is found within `timeout`.
///
/// On the first call it scans for `timeout` seconds; all subsequent calls
/// return the cached result immediately (or re-throw if the first scan found nothing).
@MainActor
func nearbyDevice(timeout: Duration = .seconds(10)) async throws -> MetaWearDevice {
    if _scanAttempted {
        guard let device = _cachedDevice else {
            throw MWError.operationFailed("No MetaWear device found — is one nearby and powered on?")
        }
        return device
    }
    _scanAttempted = true

    let scanner = MetaWearScanner()
    _cachedScanner = scanner   // prevent deallocation — transport holds unowned centralManager
    scanner.startScan()
    defer { scanner.stopScan() }

    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let device = scanner.discoveredDevices.values.first {
            _cachedDevice = device
            return device
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    throw MWError.operationFailed("No MetaWear device found after \(timeout) — is one nearby and powered on?")
}

// MARK: - Connected device scope

/// Finds a nearby device, connects, runs `body`, then always disconnects — even on throw.
@MainActor
func withConnectedDevice(_ body: (MetaWearDevice) async throws -> Void) async throws {
    let device = try await nearbyDevice()
    try await device.connect()
    do {
        try await body(device)
    } catch {
        try? await Task.sleep(for: .milliseconds(100))
        try await device.disconnect()
        throw error
    }
    // Brief pause so the BLE radio can flush any final write-without-response
    // packets (e.g. stopLED) before cancelPeripheralConnection tears the link down.
    try? await Task.sleep(for: .milliseconds(100))
    try await device.disconnect()
}
