# MetaWear Swift SDK

A clean-room Swift implementation of the MetaWear BLE protocol.
This file captures all architecture decisions made so far.

---

## Goals

- Native iOS app + reusable Swift SDK
- No dependency on MbientLab's existing SDKs
- Protocol spec sourced from: `/Users/kasso/Documents/MetaWear-API/docs/api-specification.md` (the former `protocol-reference.md` was merged into it 2026-06; its math-op table was wrong — firmware ops are Add=1…Subtract=9, Abs=10, Constant=11)

---

## Platform

- **iOS only**
- **iOS 17+** (for SwiftData)
- **Swift 6** strict concurrency (`-strict-concurrency=complete`)
- **SwiftUI** for UI (no UIKit, no cross-platform frameworks)

---

## Key Technology Decisions

| Concern | Choice | Rejected | Reason |
|---------|---|---|---|
| UI | SwiftUI + `@Observable` | UIKit, Flutter | Native, modern, less boilerplate |
| Observation | `@Observable` | `ObservableObject` + `@Published` | Swift 5.9+, less boilerplate |
| Async sequences | `AsyncThrowingStream` | Combine, `AsyncStream` | Errors propagate (BLE drops), no Combine dependency |
| Thread safety | `actor` | `DispatchQueue` + locks | Compiler-enforced, Swift 6 native |
| BLE wrapper | Custom `CoreBluetoothTransport` | AsyncBluetooth | AsyncBluetooth uses Combine for notifications |
| Persistence | SwiftData | CoreData, SQLite | iOS 17+, Swift-native |
| Live graphing | Swift Charts | Third-party | Native iOS 16+, integrates with SwiftUI |

---

## Architecture

```
┌─────────────────────────────────────┐
│         SwiftUI Views               │
│   (@Observable ViewModels)          │
├─────────────────────────────────────┤
│         MetaWearClient (actor)      │
│   DeviceState machine               │
│   Module access (accel, gyro, etc.) │
├─────────────────────────────────────┤
│         Protocol Layer              │
│   Command builders                  │
│   Response parsers                  │
│   Module registry                   │
├─────────────────────────────────────┤
│      BLETransport (protocol)        │
├───────────────┬─────────────────────┤
│ CoreBluetooth │  MockBLETransport   │
│ Transport     │  (for tests)        │
└───────────────┴─────────────────────┘
```

---

## BLETransport Protocol

The entire CoreBluetooth surface the protocol layer needs.
Swap implementations for testing without touching anything above.

```swift
protocol BLETransport: Actor {
    func connect(to identifier: UUID) async throws
    func disconnect() async throws
    func write(_ data: Data, to characteristic: CBUUID, type: CBCharacteristicWriteType) async throws
    func read(from characteristic: CBUUID) async throws -> Data
    func notify(from characteristic: CBUUID) -> AsyncThrowingStream<Data, Error>
    func scan(for services: [CBUUID]?) -> AsyncStream<ScanResult>
}
```

---

## CoreBluetoothTransport

Custom wrapper around CoreBluetooth. No third-party BLE libraries.

### Bridging strategy

CoreBluetooth is delegate/callback based. Bridge to async/await:

| CoreBluetooth callback | Bridged to |
|---|---|
| `didConnect` | `CheckedContinuation<Void, Error>` |
| `didFailToConnect` | same continuation, throw |
| `didDisconnect` | terminate notification stream with error |
| `didUpdateValueFor` (read response) | `CheckedContinuation<Data, Error>` |
| `didUpdateValueFor` (notification) | `AsyncThrowingStream.Continuation.yield()` |
| `didWriteValueFor` | `CheckedContinuation<Void, Error>` |
| `didDiscover peripheral` | `AsyncStream.Continuation.yield()` |

### Swift 6 pattern

`CBCentralManager` and `CBPeripheral` are not `Sendable`.
Delegate methods are `nonisolated`, hop back into the actor via `Task`:

```swift
actor CoreBluetoothTransport: NSObject, BLETransport {
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var notificationContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { await self.handleConnect() }
    }
}
```

---

## MetaWear UUIDs

```swift
// Service
let metaWearService    = CBUUID(string: "326A9000-85CB-9195-D9DD-464CFBBAE75A")

// Characteristics
let commandChar        = CBUUID(string: "326A9001-85CB-9195-D9DD-464CFBBAE75A") // write
let notifyChar         = CBUUID(string: "326A9006-85CB-9195-D9DD-464CFBBAE75A") // notify

// Standard BLE Device Info (service 0x180A)
let firmwareRevision   = CBUUID(string: "2A26")
let modelNumber        = CBUUID(string: "2A24")
let hardwareRevision   = CBUUID(string: "2A27")
let manufacturerName   = CBUUID(string: "2A29")
let serialNumber       = CBUUID(string: "2A25")
```

---

## Packet Format

Every command and notification:

```
Byte 0:   module_id
Byte 1:   register_id   (| 0x80 for READ requests)
Byte 2:   data_id       (only for signals with an ID)
Bytes 3+: payload       (little-endian)
```

Macros are the only commands written **with** response.
Everything else uses write-without-response.

```swift
func buildCommand(_ module: Module, _ register: UInt8, _ payload: UInt8...) -> Data {
    Data([module.rawValue, register] + payload)
}

func buildReadCommand(_ module: Module, _ register: UInt8, _ payload: UInt8...) -> Data {
    Data([module.rawValue, register | 0x80] + payload)
}
```

---

## Device State Machine

The MetaWear cannot stream and log simultaneously.
State is enforced at the actor level — invalid transitions throw.

```
Disconnected → Idle → Streaming
                    → Logging
                    → Downloading  (only when Idle, after Logging)
```

```swift
enum DeviceState: Equatable {
    case disconnected
    case idle
    case streaming(config: StreamConfig)
    case logging(config: LogConfig)
    case downloading(progress: Double)
}
```

State guards in `MetaWearClient`:
```swift
func startStreaming(config: StreamConfig) async throws {
    guard case .idle = state else { throw MetaWearError.invalidState }
    ...
}
```

---

## Data Modes

### Streaming (live)

- BLE delivers packed data: 3 samples per notification
- Effective max ~100Hz (BLE bottleneck)
- Unpacked in protocol layer → `AsyncThrowingStream`
- Fed into `@Observable` ViewModel → Swift Charts
- No persistence — display only

```
MetaWear → BLE notifications (packed ~33/sec)
         → unpack 3 samples
         → AsyncThrowingStream<SensorSample, Error>
         → @Observable ViewModel (rolling buffer)
         → Swift Charts (live graph)
```

### Logging (on-device)

- Sensor data written to MetaWear flash at up to 800Hz+
- Separate explicit download step when stopped
- Download delivers progress via callback
- Parsed log entries persisted to SwiftData

```
MetaWear flash → BLE download (burst)
              → parse log entries (tick → epoch conversion)
              → SwiftData
              → display / export
```

**MMS-specific:** must call `flush_page` before downloading.
**Tick math:** `(48.0 / 32768.0) * 1000.0 = 1.4648 ms/tick`

---

## Module IDs

```swift
enum Module: UInt8 {
    case switch_       = 0x01
    case led           = 0x02
    case accelerometer = 0x03
    case temperature   = 0x04
    case gpio          = 0x05
    case haptic        = 0x08
    case dataProcessor = 0x09
    case event         = 0x0A
    case logging       = 0x0B
    case timer         = 0x0C
    case serial        = 0x0D
    case macro         = 0x0F
    case settings      = 0x11
    case barometer     = 0x12
    case gyro          = 0x13
    case magnetometer  = 0x15
    case sensorFusion  = 0x19
    case debug         = 0xFE
}
```

---

## Board Initialization Sequence

1. Subscribe to notify characteristic (`326A9006`)
2. Read Device Info characteristics (firmware, model, hardware, manufacturer, serial)
3. Discover available modules — send `[module_id, 0x80]` for each known opcode
4. Board responds with `[module_id, 0x80, impl_id, revision]`
5. Build module registry from responses
6. Read logging time reference (`[0x0B, 0x84]`) and set epoch

Module discovery can be parallelised with `ThrowingTaskGroup` — fire all queries simultaneously rather than sequentially.

---

## Sensor Data Types

```swift
struct CartesianFloat: Sendable {
    let x: Float  // axes in physical units (g, dps, µT)
    let y: Float
    let z: Float
}

struct Quaternion: Sendable {
    let w: Float
    let x: Float
    let y: Float
    let z: Float
}

struct EulerAngles: Sendable {
    let heading: Float  // degrees
    let pitch: Float
    let roll: Float
    let yaw: Float
}

struct SensorSample: Sendable {
    let epoch: Date
    let value: SensorValue
}

enum SensorValue: Sendable {
    case acceleration(CartesianFloat)   // g
    case rotation(CartesianFloat)       // dps
    case magneticField(CartesianFloat)  // µT
    case quaternion(Quaternion)
    case eulerAngles(EulerAngles)
    case pressure(Float)                // Pa
    case altitude(Float)                // m
    case temperature(Float)             // °C
}
```

All types are `Sendable` — safe to pass across actor boundaries.

---

## Scale Factors (for parsing raw int16 responses)

### Accelerometer

| Range | BMI160 byte | BMI270 byte | Scale (LSB/g) |
|---|---|---|---|
| ±2g | 0x03 | 0x00 | 16384 |
| ±4g | 0x05 | 0x01 | 8192 |
| ±8g | 0x08 | 0x02 | 4096 |
| ±16g | 0x0C | 0x03 | 2048 |

### Gyroscope

| Range | Scale (LSB/dps) |
|---|---|
| ±2000 dps | 16.4 |
| ±1000 dps | 32.8 |
| ±500 dps | 65.6 |
| ±250 dps | 131.2 |
| ±125 dps | 262.4 |

### Other

| Sensor | Scale |
|---|---|
| Magnetometer | 16.0 LSB/µT |
| Pressure | raw ÷ 256 → Pa |
| Altitude | raw ÷ 256 → m |
| Temperature | raw ÷ 8 → °C |
| Humidity | raw ÷ 1024 → % |
| Quaternion / Euler | raw ÷ 65536 (Q16.16) |

---

## Reference Implementation — MetaWear-Swift-Combine-SDK

Source: `https://github.com/mbientlab/MetaWear-Swift-Combine-SDK`

A fully working Combine-based Swift SDK. Our rewrite replaces Combine with Swift 6 concurrency
but preserves the protocol taxonomy and data model.

### What to keep (port directly)

| File / Concept | Why |
|---|---|
| `MWActions.swift` — `MWLoggable`, `MWStreamable`, `MWPollable`, `MWReadable`, `MWCommand` | Clean orthogonal protocol taxonomy, no Combine dependency |
| All `SensorModules/` structs | Sensor config structs, scale factors, signal lookups — no Combine |
| `MWData.swift` + `copy()` pattern | C++ data pointer is only valid during callback — `copy()` on line 1 is essential |
| `MWDataConvertible` + `asColumns` | CSV/table export, zero per-sensor code at consumer level |
| `MWNamedSignal` + `DownloadUtilities` | Typed logger identifier registry, bundles stop/decode/columns per signal |
| `MWFrequency` | Bidirectional Hz↔ms value type |
| `MWError` | 4-case error enum, fits `throws` directly |
| `MWDataTable` | CSV table from streamed/downloaded data |
| `Bridging.swift` — `bridge(obj:)` / `bridge(ptr:)` | Still needed to pass Swift objects into C++ callbacks |
| `MWModules.swift` | Module detection/lookup logic |
| `cbindings.swift` | C++ integer constants re-exported as Swift |
| Sensor conflict detection | Accel/gyro/mag cannot run while SensorFusion is active — hardware constraint |
| Write queue + `peripheralIsReady` drain | BLE write throttling is real; keep as actor-isolated queue |

### What to replace entirely

| Old (Combine) | New (Swift Concurrency) |
|---|---|
| `MetaWear.swift` (class + bleQueue) | `MetaWearDevice` (actor) |
| `MetaWearScanner.swift` (class + bleQueue) | `MetaWearScanner` (actor) |
| `Combine/Stream.swift` | `func stream<S: MWStreamable>(_ s: S) -> AsyncThrowingStream` |
| `Combine/Log.swift` | `func log<L: MWLoggable>(_ l: L) async throws` |
| `Combine/Download.swift` | `func downloadLogs() -> AsyncThrowingStream<Download<[MWDataTable]>, Error>` |
| `Combine/Read.swift` | `func read<R: MWReadable>(_ r: R) async throws -> Timestamped<R.DataType>` |
| `Combine/Command.swift` | `func command<C: MWCommand>(_ c: C) async throws` |
| `Combine/Timer.swift` | `func createTimer(...) async throws -> MWTimer` |
| `Combine/RecordEvents.swift` | `func recordEvents(for:_:) async throws` |
| `Helpers/Combine+Internal.swift` | Removed |
| `Helpers/Combine+Public.swift` | Removed |
| `PassthroughSubject` one-shot | `withCheckedThrowingContinuation` |
| `PassthroughSubject` multi-value | `AsyncThrowingStream { continuation in }` |
| `CurrentValueSubject` accumulator | `var accumulated: [T] = []` inside actor |
| `bleQueue` + `handleOutputOnBleQueue` | `actor` (serialises all access automatically) |
| `AnyCancellable` lifetime management | `Task` + `withTaskCancellationHandler` |
| `flatMap` download pipeline | Straightforward `async` function with a loop |

### Key lessons from their pain points

- **`AnyCancellable` retention** — silent failure when forgotten. `Task` lifetime is explicit.
- **`PassthroughSubject` as one-shot** — no guarantee of single send. `CheckedContinuation` enforces it.
- **`flatMap` chains** — opaque stack traces. `async/await` is linear and debuggable.
- **No backpressure** on `PassthroughSubject`. `AsyncThrowingStream` supports it.
- **`eraseToAnyPublisher()` everywhere** — ~150 calls, heap-boxes every boundary. Async sequences compose without this.
- **Macro recording type break** — changing `Output` mid-chain is awkward in Combine. `async throws -> MacroID` is clean.

### Their C++ bridge pattern (we keep this)

```swift
// Pass a Swift object into a C++ callback as UnsafeMutableRawPointer
let continuation = /* CheckedContinuation or AsyncThrowingStream.Continuation */
mbl_mw_some_async_function(board, bridgeRetained(obj: continuation)) { context, result in
    let c = bridge(ptr: context!)  // recover the Swift object
    c.resume(returning: result)    // or c.yield(value)
}
```

`MblMwData*` is only valid during the C++ callback — always call `data.pointee.copy()` immediately.

---

## Open Questions

- What sensors does the user configure in the app, or is sensor config user-facing?
- Export format for logged data (CSV, JSON, custom binary)?
- Single device or multi-device support?
- Does the app need a scan/discovery screen or is the MAC address known ahead of time?

---

## Reference

Full byte-level protocol: `/Users/kasso/Documents/MetaWear-API/docs/api-specification.md`
