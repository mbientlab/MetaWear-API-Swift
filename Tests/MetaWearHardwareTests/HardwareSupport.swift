import Testing
import MetaWear
import Foundation

// MARK: - Scan cache
//
// Scans once for the first 10 seconds; subsequent calls reuse the result.
// This means the whole suite only pays one scan-timeout, not one per test.

@MainActor private var _scanTask: Task<MetaWearDevice, Error>? = nil
@MainActor private var _cachedScanner: MetaWearScanner? = nil   // keeps MWCentralManager alive

/// Returns a nearby MetaWear device, or throws if none is found within `timeout`.
///
/// On the first call it scans; all subsequent calls return the cached result
/// immediately (or re-throw if the first scan found nothing).
///
/// **Multiple boards in range:** with more than one MetaWear advertising, the
/// old behaviour ("first to answer") connected to a random board per run. Now:
///  - Set `METAWEAR_TEST_DEVICE` (peripheral-UUID prefix or advertised-name
///    substring, case-insensitive) to pin a specific board.
///  - Without the variable, the scan gathers candidates for a few seconds and
///    picks the lowest peripheral UUID — arbitrary but stable per Mac, so
///    every run hits the same board.
/// All candidates are printed so it's always visible which board was chosen.
@MainActor
func nearbyDevice(timeout: Duration = .seconds(10)) async throws -> MetaWearDevice {
    // Single shared scan task: concurrent suites all await the same scan
    // instead of racing a boolean flag (which made the second suite see
    // "scan attempted, no device" while the first was still scanning).
    if let task = _scanTask {
        return try await task.value
    }
    let task = Task { @MainActor in
        try await performScan(timeout: timeout)
    }
    _scanTask = task
    return try await task.value
}

@MainActor
private func performScan(timeout: Duration) async throws -> MetaWearDevice {
    let scanner = MetaWearScanner()
    _cachedScanner = scanner   // prevent deallocation — transport holds unowned centralManager
    scanner.startScan()
    defer { scanner.stopScan() }

    func describe(_ device: MetaWearDevice) -> String {
        let name = scanner.advertisedNames[device.identifier] ?? "?"
        return "\(name) (\(device.identifier.uuidString))"
    }

    let preference = ProcessInfo.processInfo.environment["METAWEAR_TEST_DEVICE"]?.lowercased()
    let deadline = ContinuousClock.now + timeout
    let gatherDeadline = ContinuousClock.now + .seconds(4)

    while ContinuousClock.now < deadline {
        let devices = scanner.discoveredDevices.values

        if let preference {
            if let match = devices.first(where: { device in
                device.identifier.uuidString.lowercased().hasPrefix(preference)
                    || (scanner.advertisedNames[device.identifier] ?? "").lowercased().contains(preference)
            }) {
                print("\n  Boards in range: \(devices.map(describe).joined(separator: ", "))")
                print("  Selected (METAWEAR_TEST_DEVICE=\(preference)): \(describe(match))\n")
                return match
            }
        } else if !devices.isEmpty, ContinuousClock.now >= gatherDeadline {
            // Gather window elapsed — make the stable choice.
            let chosen = devices.min { $0.identifier.uuidString < $1.identifier.uuidString }!
            print("\n  Boards in range: \(devices.map(describe).joined(separator: ", "))")
            print("  Selected (lowest UUID; set METAWEAR_TEST_DEVICE to override): \(describe(chosen))\n")
            return chosen
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    throw MWError.operationFailed(
        preference != nil
            ? "No MetaWear matching METAWEAR_TEST_DEVICE='\(preference!)' found after \(timeout)"
            : "No MetaWear device found after \(timeout) — is one nearby and powered on?"
    )
}

// MARK: - Connected device scope

/// One link in the global hardware-access queue. Swift Testing runs different
/// suites concurrently even when each is `.serialized`; two suites connecting
/// to the same cached device throw "Already connected or connecting". Every
/// `withConnectedDevice` chains onto the queue tail so exactly one test
/// touches the board at a time, across all suites. MainActor isolation makes
/// the open-before-wait ordering race-free.
@MainActor
private final class HardwareGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private var _hardwareQueueTail: HardwareGate? = nil

/// Finds a nearby device, connects, runs `body`, then always disconnects — even on throw.
/// Globally serialized across suites (see `HardwareGate`).
@MainActor
func withConnectedDevice(_ body: @MainActor (MetaWearDevice) async throws -> Void) async throws {
    let previous = _hardwareQueueTail
    let gate = HardwareGate()
    _hardwareQueueTail = gate
    await previous?.wait()
    defer { gate.open() }

    try await connectAndRun(body)
}

@MainActor
private func connectAndRun(_ body: @MainActor (MetaWearDevice) async throws -> Void) async throws {
    let device = try await nearbyDevice()
    try await device.connect()

    // Print MAC immediately after connect so every test's output is prefixed
    // with the identity of the board it ran against. Best-effort: fall back
    // to "?" on the rare board whose settings module pre-dates register 0x0B
    // rather than aborting the test.
    let mac = (try? await device.read(MWMACAddress()).value) ?? "?"
    print("\n  Connected — MAC: \(mac)\n")

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

// MARK: - Board state reset
//
// Wipe everything an event/macro/processor/logger test could have left on
// the board from a prior run. Call this at the START of any test that
// creates events, processors, macros, or loggers — leftovers from a
// previous run consume firmware slots and turn real failures into
// confusing "wrong color" / "missing event" symptoms instead.
//
// Tear-down order matters because of cross-references:
//   - events reference processors and macros (`executeMacro` action)
//   - processors reference each other (chain inputs)
//   - loggers reference processors (logged signal source)
//
// Most-dependent objects are dropped first so the firmware never sees a
// dangling reference mid-cleanup.

/// Wipe all on-device events, processors, macros, and log entries.
/// Idempotent: safe to call on a freshly connected board with nothing on it.
@MainActor
func resetBoardState(_ device: MetaWearDevice) async throws {
    try await device.removeAllEvents()      // events first — they reference everything below
    try await device.removeAllProcessors()  // processors next — they may chain to each other
    try await device.eraseAllMacros()       // macros last — referenced by event actions above
    try await device.clearLog()             // wipe flash entries from prior logging tests
}

// MARK: - Sample pretty-printing
//
// Tests that consume a streaming `for try await s in stream { ... }` loop
// often want the value displayed as it arrives. These helpers give every
// sensor a uniform tabular line — `[ n]  field: ±0.000   field: ±0.000   …  unit`
// — so test output reads consistently whether the source is the accelerometer,
// magnetometer, sensor fusion, or environment stack.
//
// Each overload picks up the right format from the value type, so call sites
// stay short:
//
// ```swift
// for try await s in stream {
//     count += 1
//     print(formatSample(count, s.value, unit: "g"))
//     samples.append(s.value)
// }
// ```

/// Format a 3-axis sample (accelerometer / gyro / magnetometer) with the
/// supplied unit suffix.
func formatSample(_ index: Int, _ v: CartesianFloat, unit: String) -> String {
    String(format: "  [%3d]  x: %+.3f   y: %+.3f   z: %+.3f   %@",
           index, v.x, v.y, v.z, unit)
}

/// Format a scalar (pressure, altitude, temperature, humidity, …).
/// Width is 9 digits before the unit so the column lines up across samples
/// whose magnitudes differ by orders of magnitude (e.g. ~101325 Pa).
func formatSample(_ index: Int, _ v: Float, unit: String) -> String {
    String(format: "  [%3d]  %+10.3f %@", index, v, unit)
}

/// Format a quaternion (w, x, y, z). Unit-less by definition — components
/// are in [-1, +1].
func formatSample(_ index: Int, _ v: Quaternion) -> String {
    String(format: "  [%3d]  w: %+.3f   x: %+.3f   y: %+.3f   z: %+.3f",
           index, v.w, v.x, v.y, v.z)
}

/// Format Euler angles. `heading` and `yaw` are both reported by sensor
/// fusion and tend to span [0, 360); pitch/roll are in [-180, +180]. A
/// 7-wide field with sign + 2 decimals fits all four cleanly.
func formatSample(_ index: Int, _ v: EulerAngles) -> String {
    String(format: "  [%3d]  heading: %+7.2f   pitch: %+7.2f   roll: %+7.2f   yaw: %+7.2f   °",
           index, v.heading, v.pitch, v.roll, v.yaw)
}

// MARK: - Advertised-name verification
//
// The MetaWear firmware does not expose a device-name read (register 0x11/0x01
// is write-only) and CoreBluetooth blocks the standard GAP Device Name
// characteristic (0x2A00). To verify that a `MWSettings.SetDeviceName` actually
// propagated to the advertising layer, we have to disconnect and observe the
// board's next advertisement packet.

/// Waits for a fresh advertisement from the peripheral identified by `uuid`
/// and returns the advertised local name. The peripheral must currently be
/// **disconnected** (MetaWear devices stop advertising while connected).
///
/// Clears the previously-captured name for the UUID so a stale value from an
/// earlier scan can't satisfy the wait — the returned name must come from a
/// scan started after this call.
@MainActor
func awaitAdvertisedName(for uuid: UUID, timeout: Duration = .seconds(5)) async throws -> String? {
    guard let scanner = _cachedScanner else {
        throw MWError.operationFailed("Scanner not initialized — call nearbyDevice() first")
    }
    scanner.clearAdvertisedName(for: uuid)
    scanner.startScan()
    defer { scanner.stopScan() }

    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let name = scanner.advertisedNames[uuid] {
            return name
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return nil
}

// MARK: - Manufacturer-data verification
//
// iOS / macOS deliver the raw manufacturer-specific advertisement payload via
// `CBAdvertisementDataManufacturerDataKey`. For a MetaWear running in iBeacon
// mode that payload begins with the Apple company ID `0x4C 0x00` followed by
// the iBeacon sub-type `0x02`, length `0x15`, 16-byte UUID, 2-byte major,
// 2-byte minor, and a 1-byte measured-RSSI reference (25 bytes total).
//
// NOTE: CoreBluetooth has historically filtered iBeacon advertisements from
// foreground scans on iOS. On macOS the payload is delivered intact; iOS
// behaviour depends on the system version and whether a background mode is
// declared. The test using this helper skips gracefully when no payload is
// observed rather than failing hard.

/// iBeacon fields parsed from an Apple-company manufacturer-specific payload.
struct ParsedIBeacon: Equatable {
    let uuid: UUID
    let major: UInt16
    let minor: UInt16
    let measuredPower: Int8   // signed dBm reference at 1 m
}

/// Decode an Apple iBeacon payload from the bytes returned by
/// `CBAdvertisementDataManufacturerDataKey`. Returns `nil` if the data is
/// not an iBeacon advertisement (wrong company ID, wrong sub-type, or wrong
/// length).
func parseIBeacon(_ data: Data) -> ParsedIBeacon? {
    // 0x4C 0x00  — Apple company ID (little-endian)
    // 0x02       — iBeacon sub-type
    // 0x15       — remaining length (21 bytes)
    // 16 bytes   — proximity UUID (big-endian on air)
    //  2 bytes   — major (big-endian)
    //  2 bytes   — minor (big-endian)
    //  1 byte    — measured RSSI reference (Int8)
    guard data.count >= 25,
          data[0] == 0x4C, data[1] == 0x00,
          data[2] == 0x02, data[3] == 0x15 else { return nil }
    let uuidBytes = data[4..<20]
    let tuple = uuidBytes.withUnsafeBytes { raw -> uuid_t in
        raw.load(as: uuid_t.self)
    }
    let uuid = UUID(uuid: tuple)
    let major = (UInt16(data[20]) << 8) | UInt16(data[21])
    let minor = (UInt16(data[22]) << 8) | UInt16(data[23])
    let measured = Int8(bitPattern: data[24])
    return ParsedIBeacon(uuid: uuid, major: major, minor: minor, measuredPower: measured)
}

/// Waits for a fresh advertisement from the peripheral identified by `uuid`
/// and returns the raw `CBAdvertisementDataManufacturerDataKey` bytes. The
/// peripheral must currently be **disconnected**.
///
/// Clears the previously-captured payload for the UUID so a stale value
/// cannot satisfy the wait.
@MainActor
func awaitManufacturerData(for uuid: UUID, timeout: Duration = .seconds(5)) async throws -> Data? {
    guard let scanner = _cachedScanner else {
        throw MWError.operationFailed("Scanner not initialized — call nearbyDevice() first")
    }
    scanner.clearManufacturerData(for: uuid)
    scanner.startScan()
    defer { scanner.stopScan() }

    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let data = scanner.advertisementManufacturerData[uuid] {
            return data
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return nil
}
