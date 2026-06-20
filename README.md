# MetaWear Swift SDK

A Swift 6 implementation of the [MetaWear protocol](https://github.com/mbientlab/MetaWear-API).

This repository contains both the reusable Swift Package products and the MetaWear app:

- Use `MetaWear` when you need the scanner, device actor, BLE transport, protocol layer, and sensor/module APIs.
- Add `MetaWearPersistence` when you want SwiftData-backed session storage and CSV export helpers.
- Add `MetaWearFirmware` only when your app needs over-the-air DFU firmware updates.
- Open `Apps/MetaWear/MetaWearApp.xcodeproj` for the full MetaWear app — see [The MetaWear App](#the-metawear-app).

## Table of Contents

| Start here | Use it for |
|------------|------------|
| [The MetaWear App](#the-metawear-app) | The full SwiftUI app — what it does, running it (incl. Demo Mode), and how it's built |
| [Quick Start](#quick-start) | Adding the package, scanning, connecting, streaming, and sending simple commands |
| [Architecture](#architecture) | Understanding the scanner/device/protocol/transport layering |
| [Supported sensors and modules](#supported-sensors-and-modules) | Finding the Swift type and configuration shape for each MetaWear module |
| [Logging](#logging) | On-device flash logging, typed downloads, anonymous logger recovery, and CSV export |
| [Persistence (SwiftData)](#persistence-swiftdata) | Saving downloaded sessions and reconstructing typed samples |
| [Testing](#testing) | Running unit tests, hardware integration tests, and the macOS CLI demo |

## Requirements

| Requirement   | Version   |
|---------------|-----------|
| Swift         | 6.0+      |
| iOS           | 17+       |
| macOS         | 14+       |
| Xcode         | 16+       |

---

## Supported boards

This SDK targets MbientLab MetaMotion boards only. Anything else (legacy MetaWear R / RG / RPro / C / CPro, MetaMotion C, MetaEnvironment, MetaTracker, MetaHealth) is treated as `MWModel.unknown` — connect / read may still work but module-level behaviour is not validated.

| Board                | Model number (`0x2A24`) | Hardware revisions (`0x2A27`)                |
|----------------------|:-----------------------:|:---------------------------------------------|
| MetaMotion R / RL    | `5`                     | `r0.1`, `r0.2`, `r0.3`, `r0.4`, `r0.5`       |
| MetaMotion S         | `8`                     | `r0.1`                                       |

`MWModel` decodes the Model Number characteristic into a typed case; `MWDeviceInformation.isHardwareRevisionSupported` cross-checks the revision against the table above:

```swift
guard let info = await device.deviceInfo else { return }
print(info.model.name)                          // "MetaMotion R / RL" or "MetaMotion S"
print(info.model.supportedHardwareRevisions)    // ["r0.1", ..., "r0.5"]  or  ["r0.1"]
if !info.isHardwareRevisionSupported {
    // Either an unsupported board model or a revision not on file.
}
```

The validator is forgiving about formatting — `"r0.4"`, `"R0.4"`, and `"0.4"` all match.

---

## What ships in this repository

| Product / target                      | Kind        | What it is                                                                                       |
|---------------------------------------|-------------|--------------------------------------------------------------------------------------------------|
| `MetaWear`                            | library     | Core SDK — scanner, device actor, BLE transport, protocol layer, every sensor module             |
| `MetaWearPersistence`                 | library     | SwiftData session storage, depends on `MetaWear`                                                  |
| `MetaWearFirmware`                    | library     | Over-the-air firmware update, wraps NordicDFU 4.16.0 (`@preconcurrency`) in an actor-isolated `DFUSession` |
| `MetaWearDemo`                        | executable  | macOS CLI that exercises the core SDK against a real board                                       |
| `Apps/MetaWear/MetaWearApp.xcodeproj` | iOS app     | MetaWear App — scan / connect / live-stream / log / download / export, SwiftData-backed sessions  |

The four SwiftPM products are intentionally split so an app can take just `MetaWear` without pulling NordicDFU or SwiftData.
Hardware integration tests (`MetaWearHardwareTests`) live in `Tests/IntegrationTests/MetaWearTestHost.xcodeproj` — see [Hardware integration tests](#hardware-integration-tests).

---

## The MetaWear App

`Apps/MetaWear/MetaWearApp.xcodeproj` is the MetaWear app — a SwiftUI app built on
the three SwiftPM products above (`MetaWear` for BLE + protocol, `MetaWearPersistence`
for storage and CSV, `MetaWearFirmware` for DFU). It doubles as the reference
consumer of the SDK: the public APIs an app needs are exercised here end to end.

### What you can do

| Area | What it does |
|------|--------------|
| **Scan & connect** | Discover nearby MetaMotion boards with live RSSI, connect, and reconnect to remembered devices |
| **Sensor config** | Choose sensors and per-sensor rate / range (e.g. accelerometer ±2 g @ 100 Hz) before streaming or logging |
| **Live Stream** | Real-time x/y/z charts with live numeric readouts and an effective-Hz indicator, a 3D orientation view driven by sensor-fusion quaternions, pause/resume, and archiving the live buffer to Session History |
| **Logging & download** | Start on-device flash logging — the board keeps recording while disconnected — then reconnect and download; interrupted sessions are recoverable |
| **Session history** | Browse saved sessions, re-plot them, and export any session to CSV (Files / AirDrop / email) |
| **Controls** | Single-shot reads (temperature, pressure, ambient light), plus LED, haptic, and other module actions |
| **Device info & settings** | Battery, signal strength, serial / firmware / model, and per-device settings |

### Running it

1. Open `Apps/MetaWear/MetaWearApp.xcodeproj` in Xcode 16+. The app targets **iOS 26** (it uses the Liquid Glass design system); the scheme is **MetaWearApp**.
2. **With hardware** — run on a physical iPhone or iPad and connect a MetaMotion board over Bluetooth.
3. **Without hardware** — run in the iOS Simulator, where **Demo Mode** turns on automatically and injects a fully simulated "Simulated MetaWear" board so every screen works (synthetic live streams, a recordable/downloadable log session, battery / RSSI, …). On a real device, pass the `-MWDemo` launch argument to force Demo Mode. See `App/DemoMode.swift`.

### How it's built

- **SwiftUI + `@Observable`**, with `NavigationSplitView` for an iPhone/iPad-adaptive layout and an iOS 26 "Liquid Glass" design system (`Designs/`).
- **`AppStore`** (`App/AppStore.swift`) is the root app state; each screen is driven by a focused `@MainActor` view model in `ViewModels/`.
- **High-rate streaming pipeline** — the BLE consume task appends samples to a non-observed ring buffer; a 33 ms throttle publishes to the UI, and the plotted series is decimated once at ingest, so charts stay smooth and stable at sensor rates up to 200 Hz (`ViewModels/StreamSessionViewModel.swift`, `ViewModels/Channel.swift`).
- **Split persistence** (`Persistence/AppModelContainer.swift`) — sessions, samples, and active log records live in a **local-only** SwiftData store, so high-volume telemetry never enters iCloud; the small remembered-devices list uses a separate **CloudKit-backed** store so boards are recognized across your Apple devices.

### Where the code lives

| Path | Contents |
|------|----------|
| `App/` | Entry point, root view, app state (`AppStore`), Demo Mode, shared sample / ring-buffer types |
| `Features/` | One folder per screen: `Scan`, `SensorConfig`, `LiveStream`, `Logging`, `Sessions`, `Controls`, `DeviceInfo`, `Settings`, `DeviceDetail` |
| `ViewModels/` | `@MainActor` view models, roughly one per feature |
| `Designs/` | Liquid Glass components, theme / palette, reusable chips and badges |
| `Persistence/` | SwiftData containers and the app-side `@Model` types |
| `Export/` | CSV exporters for logged and live-buffer sessions |

---

## Development workflow

### Repository layout

| Path | Purpose |
|------|---------|
| `Sources/MetaWear` | Core SDK: public API, protocol layer, module implementations, CoreBluetooth transport, and mocks |
| `Sources/MetaWearPersistence` | SwiftData session storage and sample reconstruction |
| `Sources/MetaWearFirmware` | Firmware catalog lookup, downloads, and Nordic DFU orchestration |
| `Sources/MetaWearDemo` | macOS CLI smoke test against real hardware |
| `Apps/MetaWear/MetaWear` | SwiftUI iOS demo app, organized by app state, view models, features, and design components |
| `Tests/MetaWearTests` | Unit tests for protocol, parsing, modules, device state, and mock transport behavior |
| `Tests/MetaWearPersistenceTests` | In-memory SwiftData persistence tests |
| `Tests/MetaWearFirmwareTests` | Firmware catalog, version, and server behavior tests |
| `Tests/MetaWearHardwareTests` | Real-device integration tests hosted by `Tests/IntegrationTests/MetaWearTestHost.xcodeproj` |

### Common commands

```bash
# Run all SwiftPM tests that do not require Bluetooth hardware.
swift test

# Run one suite while developing a module.
swift test --filter MWLEDTests

# Exercise the SDK against a nearby board from the command line.
swift run MetaWearDemo
```

### Documentation standards

Public SDK types should have `///` documentation because they surface in Xcode Quick Help and generated symbol docs. Implementation comments should explain protocol quirks, firmware ordering constraints, or concurrency reasoning; avoid comments that merely restate a line of Swift. Markdown docs should prefer small, runnable snippets and should call out whether hardware is required.

---

## Quick Start

### Add the package

In Xcode: File → Add Package Dependencies, enter the repo URL.

In `Package.swift`:

```swift
dependencies: [
    .package(url: "...", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["MetaWear"])
]
```

### Scan and connect

```swift
import MetaWear

// One scanner per app — holds the shared CBCentralManager
let scanner = MetaWearScanner()
scanner.startScan()

// Wait for devices (in a real app, drive a SwiftUI list from scanner.discoveredDevices)
try await Task.sleep(for: .seconds(5))
scanner.stopScan()

guard let device = scanner.discoveredDevices.values.first else { return }
try await device.connect()
```

### Stream the accelerometer

```swift
let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
let stream = try await device.startStream(sensor)

for try await sample in stream {
    print(sample.time, sample.value.x, sample.value.y, sample.value.z)
}

try await device.stopStreaming(sensor)
```

### Control the LED

```swift
// Set a pattern then play it
try await device.send(MWLED.SetPattern(color: .green, .breathe))
try await device.send(MWLED.Play())

// Stop and clear after 3 seconds
try await Task.sleep(for: .seconds(3))
try await device.send(MWLED.Stop())
```

### Buzz the haptic motor

```swift
try await device.send(MWHaptic.motor(dutyCycle: 80, pulseWidth: 500))
```

---

## Architecture

```
┌──────────────────────────────────────────────┐
│  Your App / SwiftUI Views                    │
│  (@Observable ViewModels, Swift Charts)      │
├──────────────────────────────────────────────┤
│  MetaWearScanner  (@Observable @MainActor)   │
│  MetaWearDevice   (actor)                    │
├──────────────────────────────────────────────┤
│  Module layer                                │
│  MWAccelerometer, MWGyroscope, MWLED,        │
│  MWTimer, MWEvent, MWMacro, MWGPIO, …        │
├──────────────────────────────────────────────┤
│  MWProtocolLayer  (actor)                    │
│  MWPacketParser   (static helpers)           │
├──────────────────────────────────────────────┤
│  BLETransport     (protocol)                 │
├───────────────────┬──────────────────────────┤
│  MWCentralManager │ CoreBluetoothPeripheral  │
│  (shared)         │ Transport (per device)   │
├───────────────────┴──────────────────────────┤
│  MockBLETransport  (unit tests, SwiftPM)     │
│  MetaWearTestHost.xcodeproj (hardware tests) │
└──────────────────────────────────────────────┘
```

### Key design decisions

| Concern           | Choice                                    | Why                                                           |
|-------------------|-------------------------------------------|---------------------------------------------------------------|
| Async sequences   | `AsyncThrowingStream`                     | Errors propagate on BLE drop; no Combine dependency           |
| Thread safety     | `actor`                                   | Compiler-enforced, Swift 6 native                             |
| BLE wrapper       | Custom `CoreBluetoothTransport`           | Third-party libs use Combine for notifications                |
| Observation       | `@Observable`                             | SwiftUI-native, less boilerplate than `ObservableObject`      |
| Hardware tests    | Separate Xcode project with app test host | CoreBluetooth denies BT permission to `swift test` on macOS   |

---

## Layer-by-layer breakdown

### MetaWearScanner

`@Observable @MainActor` class — safe to bind directly to SwiftUI views. 
Owns a single `MWCentralManager` (which owns the `CBCentralManager`). 
Each discovered peripheral gets its own isolated `CoreBluetoothPeripheralTransport` and `MetaWearDevice`.

```swift
public final class MetaWearScanner {
    public private(set) var discoveredDevices: [UUID: MetaWearDevice]
    public private(set) var advertisedNames:   [UUID: String]   // most-recent local name per UUID
    public private(set) var isScanning: Bool

    public func startScan()
    public func stopScan()
    public func clearAdvertisedName(for uuid: UUID)             // force next scan to recapture
}
```

`advertisedNames` is updated on every scan result, **before** the MetaWear-prefix filter, so a device that has been renamed via `MWSettings.SetDeviceName` (and no longer advertises as `"MetaWear…"`) is still observable by UUID. Combined with `clearAdvertisedName(for:)`, this is how the settings integration test verifies that a rename reached the air.

### MetaWearDevice

`actor` — all state is actor-isolated, thread-safe by default. 
Enforces the device state machine at compile time; invalid transitions throw `MWError.invalidState`.

```
.disconnected → .idle → .streaming
                      → .logging
                      → .downloading(progress:)
```

Key methods:

```swift
public func connect() async throws
public func disconnect() async throws

public func startStream<S: MWStreamable>(_ sensor: S, usePacked: Bool = true)
    async throws -> AsyncThrowingStream<Timestamped<S.Sample>, Error>
public func stopStreaming<S: MWStreamable>(_ sensor: S) async throws

public func startLogging<L: MWLoggable>(_ loggable: L) async throws
public func stopLogging<L: MWLoggable>(_ loggable: L) async throws

public func downloadLogs() async throws -> AsyncThrowingStream<Download<[RawLogEntry]>, Error>
public func downloadLogs<L: MWLoggable>(_ loggable: L)
    async throws -> AsyncThrowingStream<Download<[MWLoggedSample<L.Sample>]>, Error>
public func clearLog() async throws
@discardableResult public func flushLogPage() async throws -> Bool

public func read<R: MWReadable>(_ readable: R) async throws -> Timestamped<R.Sample>
public func poll<P: MWPollable>(_ readable: P, every: Duration)
    -> AsyncThrowingStream<Timestamped<P.Sample>, Error>
public func send(_ command: any MWCommand) async throws
public func send(_ sequence: any MWCommandSequence) async throws
```

### BLE transport split

The single `CBCentralManager` is shared across all devices; per-peripheral state is isolated:

| Type                                  | Role                                                                                                                                              |
|---------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `MWCentralManager`                    | Owns `CBCentralManager`. Routes `didConnect`/`didDisconnect` to the correct device transport by UUID. Internal.                                   |
| `CoreBluetoothPeripheralTransport`    | One per device. Owns `CBPeripheral`, characteristics, read/write continuations, notify streams, write queue. Implements `BLETransport`. Internal. |
| `MockBLETransport`                    | Public in-memory transport for unit tests. Inject notifications with `inject(notification:to:)`. No hardware required.                            |

Both real transports use the `nonisolated` delegate pattern.
CoreBluetooth callbacks hop back into the actor via `Task { await self.handle…() }`.

### MWProtocolLayer

Routes raw BLE notification bytes to the right handler by `(module_id, register_id)` key:

- Read responses (`register | 0x80` bit set) → resume the parked `CheckedContinuation`
- Unsolicited notifications → yield to the subscribed `AsyncThrowingStream.Continuation`
- Multiple concurrent reads on the same key are queued and resolved FIFO
- All waiters and streams are failed when `stop()` is called (e.g. on disconnect)

---

## Sensor protocols

Every sensor type is a pure Swift value that conforms to one of these protocols:

```swift
// Streams data continuously (accelerometer, gyro, magnetometer, sensor fusion, barometer)
protocol MWStreamable: MWSensor {
    associatedtype Sample: Sendable
    func parseSample(from packet: Data) throws -> Sample
    func parsePackedSamples(from packet: Data) throws -> [Sample]
}

// Streams AND logs to on-device flash
protocol MWLoggable: MWStreamable {
    var loggerKey: String { get }
}

// Fire-and-forget commands (LED, haptic, debug, timer control, GPIO, macro)
protocol MWCommand: Sendable {
    var commandData: Data { get }
}

// Fire-and-forget actions that require more than one BLE write
// (e.g. BMI270 feature enable/disable pairs, long scan-response splits)
protocol MWCommandSequence: Sendable {
    var commands: [Data] { get }
}

// One-shot read sensors (battery, MAC, humidity, log length, …)
protocol MWReadable: MWSensor {
    associatedtype Sample: Sendable
    var readCommand: Data { get }
    func parseSample(from packet: Data) throws -> Sample
}

// A readable whose value changes over time — works with `device.poll(_:every:)`
protocol MWPollable: MWReadable {}
```

`device.send(_:)` is overloaded for both commands and sequences — a single call site regardless of whether the action emits one or many writes.

### Generic read and poll

Any `MWReadable` works with the generic `device.read(_:)` helper; any
`MWPollable` also works with `device.poll(_:every:)` which returns an
`AsyncThrowingStream`:

```swift
let humidity = try await device.read(MWHumidity())          // Timestamped<Float>
let entries  = try await device.read(MWLogLength())         // Timestamped<UInt32>
let mac      = try await device.read(MWMACAddress())        // Timestamped<String>
let reset    = try await device.read(MWLastResetTime())     // Timestamped<MWLastResetTime.Reading> — { epoch: Date, resetUID: UInt8 }

for try await sample in await device.poll(MWSettings.ReadBatteryState(), every: .seconds(30)) {
    updateBatteryUI(sample.value)
}
```

`poll` reads the sensor, yields the timestamped sample, sleeps for the given `Duration`, and repeats. Cancelling the enclosing `Task` or breaking out of the `for await` loop stops the loop and ends the stream.

Built-in `MWPollable` conformers: `MWLogLength`, `MWLastResetTime`, `MWMACAddress`, `MWSettings.ReadBatteryState`, `MWSettings.ReadPowerStatus`, `MWSettings.ReadChargeStatus`, `MWHumidity`, `MWBarometerPressureRead`, `MWThermometer`, `MWSensorFusionCalibrationState`.

---

## Supported sensors and modules

### Accelerometer

```swift
// BMI160 (MetaMotion R / RL — model 5)
// ODR: .hz0_78 … .hz1600
// Range: .g2, .g4, .g8, .g16
let acc = MWAccelerometerBMI160(odr: .hz100, range: .g2)

// BMI270 (MetaMotion S — model 8)
// Same ODR / Range options as BMI160
let acc = MWAccelerometerBMI270(odr: .hz100, range: .g2)
```

Packed data (3 samples per BLE packet) is used automatically when `usePacked: true` (default). 
Scale factors (LSB/g): ±2g = 16384, ±4g = 8192, ±8g = 4096, ±16g = 2048.

### Gyroscope

```swift
// BMI160 (MetaMotion R / RL — model 5)
// ODR: .hz25 … .hz3200
// Range: .dps125, .dps250, .dps500, .dps1000, .dps2000
let gyro = MWGyroscopeBMI160(odr: .hz100, range: .dps2000)

// BMI270 (MetaMotion S — model 8)
// Same options as BMI160
let gyro = MWGyroscopeBMI270(odr: .hz100, range: .dps2000)
```

### Bosch motion detectors (accelerometer interrupts)

Orientation, any-motion, and tap interrupts are generated on-chip by the BMI160 / BMI270.
Configure + enable the detector, then subscribe to the accelerometer interrupt register to receive decoded events.

```swift
// Orientation — fires when the device rotates through one of 8 states (register 0x11)
// BMI160-only; constructing with `.bmi270` throws MWError.operationFailed.
try await device.send(MWAccelerometerBosch.EnableOrientation(chip: .bmi160))

// Consume raw [0x03, 0x11, byte] notifications and decode:
let orientation = try MWAccelerometerBosch.parseOrientation(from: packet)

// Any-motion — fires when motion exceeds threshold on any axis (register 0x0b)
try await device.send(MWAccelerometerBosch.ConfigureAnyMotion(
    chip: .bmi160, count: 4, thresholdG: 0.75, rangeG: 8.0
))

try await device.send(MWAccelerometerBosch.EnableAnyMotion())
let event = try MWAccelerometerBosch.parseAnyMotion(from: packet)
// event.isPositive, event.xAxisActive / yAxisActive / zAxisActive

// Tap — single + double tap (register 0x0e)
try await device.send(MWAccelerometerBosch.ConfigureTap(
    shockTime: .ms50, quietTime: .ms30, doubleTapWindow: .ms250,
    thresholdG: 2.0, rangeG: 8.0
))
let tap = try MWAccelerometerBosch.parseTap(from: packet)   // tap.type, tap.isPositive
```

### BMI270 extra features (activity, wrist, no-motion, downsampling)

BMI270-only features exposed via `MWAccelerometerBMI270Features`. `Configure…` and `SetDownsampling` conform to `MWCommand`;
the `Enable…` / `Disable…` pairs (which emit both `FEATURE_INTERRUPT_ENABLE` and `FEATURE_ENABLE` writes) conform to `MWCommandSequence`.
Both ship through the same `device.send(_:)` entry point.

```swift
// Activity classification — still / walking / running / unknown (register 0x0C, bit 0x04)
try await device.send(MWAccelerometerBMI270Features.EnableActivityDetection())
// then consume [0x03, 0x0C, byte] notifications:
let activity = try MWAccelerometerBMI270Features.parseActivity(from: packet)

// Wrist gesture (register 0x0A, bit 0x10) — push-arm-down, pivot-up, shake, arm-flick in/out
try await device.send(MWAccelerometerBMI270Features.ConfigureWristGesture(arm: .right))
try await device.send(MWAccelerometerBMI270Features.EnableWristGesture())
// … subscribe to register 0x0A …
let event = try MWAccelerometerBMI270Features.parseWristEvent(from: packet)
// event.kind == .gesture / .wakeup ; event.gestureCode

// Wrist wakeup (register 0x0A, bit 0x08) — shares parse path with wrist gesture
try await device.send(MWAccelerometerBMI270Features.ConfigureWristWakeup())
try await device.send(MWAccelerometerBMI270Features.EnableWristWakeup())

// No-motion (register 0x09, bit 0x20) — distinct from any-motion (bit 0x40)
let noMotion = try MWAccelerometerBMI270Features.ConfigureNoMotion(
    duration: 5, threshold: 0xAA,
    selectX: true, selectY: true, selectZ: true
)
try await device.send(noMotion)
try await device.send(MWAccelerometerBMI270Features.EnableNoMotion())

// FIFO downsampling (register 0x11) — reduce logged sample rate per axis-group
let downsampling = try MWAccelerometerBMI270Features.SetDownsampling(
    gyroOrdinal: 2, gyroFilterData: true,
    accOrdinal: 2,  accFilterData: true
)
try await device.send(downsampling)
```

### Magnetometer (BMM150)

```swift
let mag = MWMagnetometer(preset: .lowPower)
// Presets: .lowPower, .regular, .enhancedRegular, .highAccuracy
// Scale: 16 LSB/µT
```

### Barometer (BMP280)

```swift
let baro = MWBarometer(oversampling: .standard, iirFilter: .avg4, standbyTime: .ms62_5)
// Pressure in Pa (dataRegister 0x01), altitude in m via MWAltimeter (0x02)
```

### Ambient Light (LTR329, module 0x14)

```swift
let als = MWAmbientLight(
    gain: .x1,                          // .x1 .x2 .x4 .x8 .x48 .x96
    integrationTime: .ms100,            // .ms50 … .ms400
    measurementRate: .ms500             // .ms50 … .ms2000
)
let stream = try await device.startStream(als)
for try await sample in stream {
    let lux = MWAmbientLight.lux(from: sample.value)   // raw UInt32 milli-lux → Float lux
    print("ambient:", lux, "lx")
}
```

### Humidity (BME280, module 0x16 — MetaEnvironment)

```swift
// One-shot read
let percent = try await device.readHumidity()          // Float, % RH
print("humidity:", percent, "%")

// Configure oversampling once per session (.x1 .x2 .x4 .x8 .x16)
try await device.setHumidityOversampling(.x4)
```

### Sensor Fusion (BMM150 + BMI160/270)

```swift
MWSensorFusionQuaternion(mode: .ndof)         // → Quaternion  (w, x, y, z)
MWSensorFusionEuler(mode: .ndof)              // → EulerAngles (heading, pitch, roll, yaw)
MWSensorFusionGravity(mode: .imuPlus)         // → CartesianFloat (g)
MWSensorFusionLinearAcceleration(mode: .ndof) // → CartesianFloat (g, gravity removed)
// Modes: .ndof (9-DOF), .imuPlus (6-DOF), .compass, .m4g
```

The fusion module is fed by the underlying accelerometer + gyroscope (+ magnetometer for `.ndof` / `.compass` / `.m4g`) on the same board. `startStream` / `startLogging` configures and starts those underlying sensors for you — but the BMI160 and BMI270 chips encode their config bytes differently, so the fusion struct needs to know which chip is on the board. Pass it via `chip:` (defaults to `.bmi160`):

```swift
// Auto-detect from the gyro module's implementation byte
// (0 = BMI160 on MetaMotion R / RL, 1 = BMI270 on MetaMotion S).
// Falls back to .bmi160 if the board reports something unexpected.
let chip: MWSensorFusionChip = {
    if let impl = await device.moduleInfo(for: .gyro)?.implementation,
       let c = MWSensorFusionChip(gyroImpl: impl) { return c }
    return .bmi160
}()

let q = MWSensorFusionQuaternion(mode: .ndof, chip: chip)
let stream = try await device.startStream(q)
```

If you skip the chip argument, the SDK assumes BMI160. On a MetaMotion S (BMI270) the underlying acc/gyro will receive the wrong config bytes silently — the fusion algorithm will run, but at the wrong ODR / range — so always pass the detected chip on those boards.

### LED (module 0x02)

```swift
// Single channel
try await device.send(MWLED.SetPattern(color: .green, .blink))
try await device.send(MWLED.Play())
try await device.send(MWLED.Stop())                    // stop + clear (default)
try await device.send(MWLED.Stop(clearPattern: false)) // pause only

// Built-in presets
// .solid   — always on (lowIntensity == highIntensity, never dims)
// .blink   — 50 ms on / 450 ms off
// .breathe — ramp up/down over 2 s (725 ms rise/fall)
// .flash   — 3 short 100 ms pulses

// Multi-channel shorthand — sets patterns and plays in one call
try await device.setLED(
    red:   MWLEDPattern(highIntensity: 10, riseTime: 100, highTime: 200,
                        fallTime: 100, pulseDuration: 800, repeatCount: 0),
    green: MWLEDPattern(highIntensity: 31, riseTime: 100, highTime: 300,
                        fallTime: 100, pulseDuration: 800, repeatCount: 0),
    autoPlay: true
)
try await device.stopLED()
```

Colors: `.green` (0), `.red` (1), `.blue` (2). Intensity 0–31. `repeatCount: 0` = infinite.

### GPIO (module 0x05)

```swift
// Digital output
try await device.send(MWGPIO.SetHigh(pin: 0))
try await device.send(MWGPIO.SetLow(pin: 0))
try await device.send(MWGPIO.SetPull(pin: 0, pull: .up))   // .up / .down / .none

// One-shot reads
let state:    Bool  = try await device.readDigital(pin: 0)
let adcCount: UInt16 = try await device.readAnalogADC(pin: 0)      // raw 10-bit ADC count (0–1023)
let voltage:  UInt16 = try await device.readAnalogAbsolute(pin: 0) // millivolts (0–3300)

// Pin-change stream
let signal = MWGPIOPinChange(pin: 0, type: .any)  // .rising / .falling / .any
let stream = try await device.startStream(signal)
for try await sample in stream {
    print("pin \(sample.value.pin) → \(sample.value.isHigh ? "high" : "low")")
}
```

### Switch / Button (module 0x01)

```swift
let stream = try await device.startStream(MWSwitch())
for try await event in stream {
    print(event.value ? "pressed" : "released")
}
```

### Haptic (module 0x08)

```swift
try await device.send(MWHaptic.motor(dutyCycle: 80, pulseWidth: 500))  // ERM motor
try await device.send(MWHaptic.buzzer(pulseWidth: 200))                 // piezo buzzer
```

### Temperature (module 0x04)

```swift
let celsius = try await device.readTemperature(channel: 0)
// Channels: 0 = NRF die, 1 = external thermistor, 2 = Bosch IMU, 3 = BMP280
```

### Timer (module 0x0C)

On-device periodic timer — fires completely independently of BLE once started.

```swift
// Create and start a 500 ms repeating timer
let timer = try await device.createTimer(periodMs: 500)
try await device.setTimerNotify(timer, enabled: true)
try await device.startTimer(timer)

// Stream tick notifications over BLE
let ticks = await device.streamTimer(timer)
for try await timerID in ticks { ... }

// Tear down
try await device.stopTimer(timer)
try await device.setTimerNotify(timer, enabled: false)
try await device.removeTimer(timer)

// Parameters
device.createTimer(periodMs: 1000, repetitions: MWTimer.infinite, immediate: false)
// repetitions: 0xFFFF = MWTimer.infinite; immediate: true fires at t=0
```

### Event (module 0x0A)

Bind a board signal (timer tick, button press, GPIO change) to a command that executes on-board — no BLE connection required once configured.

```swift
// Flash green LED every time timer fires — works even if BLE disconnects
let timer = try await device.createTimer(periodMs: 500)
try await device.send(MWLED.SetPattern(color: .green, .blink))
let event = try await device.createEvent(
    source: .timerFired(timer),
    action: try MWEventAction(command: MWLED.Play())
)
try await device.startTimer(timer)

// Other event sources
MWEventSource.buttonChanged()        // fires on every button state change
MWEventSource.gpioChanged(pin: 0)    // fires on GPIO pin-change notification
MWEventSource.disconnected()         // fires when host drops connection (settings rev ≥ 2)

// Tear down
try await device.removeEvent(event)
try await device.removeAllEvents()
```

#### Source → destination data slicing (`MWEventDataToken`)

Optional instruction appended to the ENTRY command that tells the firmware to copy `length` bytes starting at `sourceOffset` of the source signal's payload into the destination command's params starting at `destOffset` when the event fires.
Without a token the destination params are written as-is.

```swift
// Route 4 bytes from source offset 2 into destination offset 3
let event = try await device.createEvent(
    source: .timerFired(timer),
    action: action,
    dataToken: try MWEventDataToken(length: 4, sourceOffset: 2, destOffset: 3)
)
// Constraints: length 1…7 (3 bits), sourceOffset 0…15 (4 bits), destOffset any UInt8
```

### Macro (module 0x0F)

Record a sequence of commands into device flash. 
Execute manually or automatically on every power-on.

```swift
// Record: set pattern + play (stored in flash)
let macro = try await device.recordMacro(
    executeOnBoot: false,
    commands: [
        MWLED.SetPattern(color: .green, .blink),
        MWLED.Play()
    ]
)

// Execute manually
try await device.executeMacro(macro)

// Or record a boot macro — runs automatically on every power-on
let bootMacro = try await device.recordMacro(
    executeOnBoot: true,
    commands: [MWLED.SetPattern(color: .blue, .flash), MWLED.Play()]
)

// Erase all macros
try await device.eraseAllMacros()
```

Commands longer than 13 bytes are split into ADD_PARTIAL + ADD_COMMAND packets automatically.

#### Embedding `createEvent` in a macro

Use the closure-based overload when the macro needs to embed a multi-write
action — `createEvent(...)` being the primary case. The recorder buffers each
call's wire bytes and replays them under one BEGIN…END recording session, so
the firmware re-creates the event binding every time the macro runs.

```swift
// Bind button → green LED flash, persisted across reboots
let macro = try await device.recordMacro(executeOnBoot: true) { recorder in
    await recorder.send(MWLED.SetPattern(color: .green, .flash))
    try await recorder.createEvent(
        source: .buttonChanged(),
        action: try MWEventAction(command: MWLED.Play())
    )
}
```

`MWMacroRecorder` exposes `send(_: MWCommand)`, `send(_: MWCommandSequence)`,
`sendRaw(_: Data)`, and `createEvent(source:action:dataToken:)`. Embedded
events do not return an `MWEvent.id` — the firmware assigns a fresh ID at
replay time. Use `removeAllEvents()` (or `eraseAllMacros()` to also clear
persistence) for cleanup.

### Serial Passthrough — I2C / SPI (module 0x0D)

Communicate with external sensors or ICs wired to the MetaWear's I2C or SPI bus.

#### I2C write

```swift
// Write 0x00 to register 0x6B of the device at I2C address 0x68 (e.g. wake an MPU-6050)
try await device.send(try MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0x00]))
```

#### I2C read

```swift
// Read 1 byte from register 0x75 (WHO_AM_I) of the device at 0x68
let bytes = try await device.i2cRead(deviceAddress: 0x68, registerAddress: 0x75, length: 1)
print("WHO_AM_I:", bytes.map { String(format: "0x%02X", $0) })
```

#### SPI write

```swift
// Send 0x9F (READ_ID) over SPI at 1 MHz, mode 3, MSB-first
try await device.send(MWSerial.SPIWrite(
    slaveSelect: 0,
    clock: .f1MHz,
    mode: .mode3,
    data: [0x9F]
))
```

#### SPI read

```swift
// Read 3 bytes from the SPI peripheral (e.g. flash JEDEC ID after sending 0x9F)
let id = try await device.spiRead(slaveSelect: 0, clock: .f1MHz, mode: .mode3, length: 3)
```

SPI clock options: `.f125kHz` `.f250kHz` `.f500kHz` `.f1MHz` `.f2MHz` `.f4MHz` `.f8MHz`  
SPI modes: `.mode0` (CPOL=0/CPHA=0) `.mode1` `.mode2` `.mode3` (CPOL=1/CPHA=1)

---

### iBeacon (module 0x07)

```swift
try await device.send(MWiBeacon.SetUUID(uuid: UUID()))
try await device.send(MWiBeacon.SetMajor(1))
try await device.send(MWiBeacon.SetMinor(2))
try await device.send(MWiBeacon.SetTXPower(-4))
try await device.send(MWiBeacon.SetPeriod(700))   // ms
try await device.send(MWiBeacon.Enable())
// ...
try await device.send(MWiBeacon.Disable())
```

### Data Processor (module 0x09)

The data processor lets you chain on-device signal transforms so the board filters and reduces
data before it ever reaches your app over BLE.

#### Create a processor:

```swift
// RSS of raw accelerometer — reduces 3-axis to a scalar magnitude
let rssHandle = try await device.createProcessor(
    MWDataProcessor.RSS(),
    source: MWAccelerometerSignal())

// Average the RSS output over a 4-sample window
let avgHandle = try await device.createProcessor(
    MWDataProcessor.Average(sampleSize: 4),
    source: rssHandle)

// Threshold — emit when the average crosses 0.5g (= 8192 / 16384 scale factor)
let threshHandle = try await device.createProcessor(
    MWDataProcessor.Threshold(boundary: 8192, hysteresis: 0, mode: .binary, signed: false),
    source: avgHandle)
```

#### Stream a processor's output:

```swift
let stream = try await device.streamProcessor(threshHandle)
for try await packet in stream {
    // packet = [0x09, 0x03, proc_id, data_bytes...]
    let value = Int32(littleEndian: packet.dropFirst(3).withUnsafeBytes { $0.load(as: Int32.self) })
    print("threshold crossed:", value > 0 ? "above" : "below")
}
```

#### Stop and remove:

```swift
try await device.stopStreamingProcessor(threshHandle)
try await device.removeProcessor(threshHandle)

// Remove everything:
try await device.removeAllProcessors()
```

#### Available processor types:

| Type          | Class                         | Output                                                    |
|---------------|-------------------------------|-----------------------------------------------------------|
| Passthrough   | `MWDataProcessor.Passthrough` | Gate — pass all / conditional / count                     |
| Accumulator   | `MWDataProcessor.Accumulator` | Running sum                                               |
| Counter       | `MWDataProcessor.Counter`     | Event count                                               |
| Average (LPF) | `MWDataProcessor.Average`     | Rolling average                                           |
| RMS combiner  | `MWDataProcessor.RMS`         | Scalar magnitude (root-mean-square)                       |
| RSS combiner  | `MWDataProcessor.RSS`         | Scalar magnitude (root-sum-square)                        | 
| Time delay    | `MWDataProcessor.Time`        | Rate-limited samples (absolute or differential)           |
| Math          | `MWDataProcessor.Math`        | Arithmetic transform (+ – × ÷ %, shifts, abs, √, etc.)    |
| Sample delay  | `MWDataProcessor.Sample`      | Burst of N buffered samples                               |
| Comparator    | `MWDataProcessor.Comparator`  | Filter by compare against a reference                     |
| Threshold     | `MWDataProcessor.Threshold`   | Crossing events (absolute or binary ±1)                   |
| Delta         | `MWDataProcessor.Delta`       | Emit when input changes by ≥ magnitude                    |
| Pulse         | `MWDataProcessor.Pulse`       | Detect pulses → emit width / area / peak / on-detect      |
| Buffer        | `MWDataProcessor.Buffer`      | Hold last sample (read on demand or fused)                |
| Packer        | `MWDataProcessor.Packer`      | Pack N samples per BLE packet                             |
| Accounter     | `MWDataProcessor.Accounter`   | Prepend timestamp or packet counter                       |
| Fuser         | `MWDataProcessor.Fuser`       | Combine latest primary + up to 12 buffered secondaries    |

Chaining — `MWProcessorHandle` conforms to `MWSignal`, so any processor's output can feed directly into the next `createProcessor` call. 
The handle carries the board-assigned ID plus the output channel count, channel width, and signedness so the next stage's config bytes are computed correctly without any manual bookkeeping.

#### Recipes

Common processor chains. Each recipe lists how many on-device processor slots
it consumes (the board has a fixed pool — typically 28).

**Fire on every Nth event** — count, take mod N, compare. Pair two comparators
sharing the modulo output to split a stream into N classes (e.g. odd/even).

```swift
// Bind switch presses
let pressed = try await device.createProcessor(
    MWDataProcessor.Comparator(operation: .eq, reference: 1, signed: false),
    source: MWSwitchSignal())                                      // slot 1

// Counter → Math(% N) → two Comparators
let counter = try await device.createProcessor(
    MWDataProcessor.Counter(outputSize: 1), source: pressed)        // slot 2
let modN = try await device.createProcessor(
    MWDataProcessor.Math(operation: .modulo, rhs: 2,
                         signed: false, outputSize: 1),
    source: counter)                                                // slot 3
let isEven = try await device.createProcessor(
    MWDataProcessor.Comparator(operation: .eq, reference: 0,
                               signed: false), source: modN)         // slot 4
let isOdd  = try await device.createProcessor(
    MWDataProcessor.Comparator(operation: .eq, reference: 1,
                               signed: false), source: modN)         // slot 5

// `isEven` / `isOdd` now act as event sources. Bind each with `createEvent`.
```

Slot cost: 5 (or 4 if you only need one of odd/even, or 3 if you don't need the
press-edge filter and the source already gives you a single-sample-per-event signal).

**Activity gate (magnitude crosses threshold)** — reduce 3-axis to scalar, then
threshold or compare. Useful for activity / freefall / impact detection without
streaming raw axes.

```swift
let mag = try await device.createProcessor(
    MWDataProcessor.RSS(),
    source: MWAccelerometerSignal())                                // slot 1
let active = try await device.createProcessor(
    MWDataProcessor.Threshold(boundary: 8192,        // 0.5 g at ±2 g range
                              hysteresis: 0,
                              mode: .binary,
                              signed: false),
    source: mag)                                                    // slot 2
// `active` emits +1 on rising edge, –1 on falling edge.
```

Slot cost: 2. Bind `active` as an event source to drive an LED, or feed into
`startLogging(_:key:)` (see [Logging a processor handle](#logging-a-processor-handle))
to record activity transitions to flash.

**Throttle a high-rate signal before logging** — Time(absolute) takes one
sample per period. Pairs naturally with the processor-handle logging API.

```swift
let euler = MWSensorFusionEuler(mode: .ndof, chip: .bmi270)
try await device.prepareSignalSource(euler)
let throttle = try await device.createProcessor(
    MWDataProcessor.Time(periodMs: 1000, mode: .absolute),
    source: MWSensorFusionEulerSignal())                            // slot 1
try await device.startLogging(throttle, key: "euler-1hz")
// ... time passes ...
try await device.stopLogging(key: "euler-1hz")
try await device.teardownSignalSource(euler)
```

Slot cost: 1. `mode: .differential` outputs the *delta* between successive
periods instead of a raw sample — handy for derivative-style telemetry.

> Cleanup: chains hold each processor's slot until you call
> `device.removeProcessor(_:)` (or `removeAllProcessors()`). Events bound to a
> processor must be torn down first (`removeAllEvents()`) — events reference
> processors, processors reference each other, and the firmware will reject a
> remove that has live downstream consumers.

---

### Settings (module 0x11)

```swift
try await device.send(MWSettings.SetDeviceName("MySensor"))                  // max 26 ASCII bytes (truncates)
try await device.send(MWSettings.SetDeviceName(validating: "MySensor"))      // throws on invalid chars / length
try await device.send(MWSettings.SetTXPower(.minus4))        // BLE TX power
```

**Verifying a device-name change.** The firmware exposes `SetDeviceName` (register 0x11/0x01) as a write-only opcode — there is no protocol read-back. The standard GAP `Device Name` characteristic (0x2A00) is also unusable: Apple's CoreBluetooth filters services 0x1800 / 0x1801 out of discovery on iOS and macOS. To confirm a rename took effect you must disconnect and observe the next advertisement:

```swift
try await device.send(MWSettings.SetDeviceName("MySensor"))
try await device.disconnect()
try await Task.sleep(for: .milliseconds(500))          // let the radio resume advertising

scanner.clearAdvertisedName(for: device.identifier)     // discard pre-rename cache
scanner.startScan()
// poll scanner.advertisedNames[device.identifier] ...
```

### Debug (module 0xFE)

```swift
try await device.send(MWDebug.Reset())            // soft reset (BLE drops)
try await device.send(MWDebug.JumpToBootloader()) // DFU mode
try await device.send(MWDebug.Disconnect())       // board-initiated disconnect
try await device.send(MWDebug.ResetAfterGC())     // reset after macro GC
try await device.send(MWDebug.EnablePowerSave())  // low-power sleep
```

---

## Logging

### Start / stop / download

```swift
let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

try await device.startLogging(sensor)
// ... time passes, board logs to flash at up to 800 Hz ...
try await device.stopLogging(sensor)

// Typed download — progress + decoded samples
let stream = try await device.downloadLogs(sensor)
for try await progress in stream {
    print("\(Int(progress.percentComplete * 100))%  \(progress.data.count) samples so far")
}

try await device.clearLog()
```

### Flushing the last log page (MMS only)

MetaMotion S boards (logging revision ≥ 3) buffer the final partial flash page in RAM. 
Call `flushLogPage()` to force that buffer to flash before downloading — without it, the last few seconds of samples may be missing from the download.
On older boards the call is a no-op and returns `false`.

```swift
try await device.stopLogging(sensor)
let flushed = try await device.flushLogPage()   // true on MMS, false elsewhere
let stream  = try await device.downloadLogs(sensor)
```

### CSV export

Any array of logged or streamed samples can be converted to a `MWDataTable` and exported as CSV. 
All sensor sample types (`CartesianFloat`, `Quaternion`, `EulerAngles`, `Float`, `Bool`, `CorrectedCartesianFloat`) conform to `MWDataConvertible` automatically.

```swift
// From logged samples
let table = MWDataTable.from(logged: entries, name: "acceleration")
print(table.csvString)
try table.writeCSV(to: URL(fileURLWithPath: "/tmp/accel.csv"))

// From streamed samples
var streamed: [Timestamped<CartesianFloat>] = []
// ... fill from stream ...
let table = MWDataTable.from(streamed: streamed, name: "acceleration")
```

### Sensor fusion calibration

```swift
// Read calibration while sensor fusion is running (0 = uncalibrated, 3 = fully calibrated)
let cal = try await device.readFusionCalibration()
print("Accel: \(cal.accelerometer)  Gyro: \(cal.gyroscope)  Mag: \(cal.magnetometer)")
```

### Auto-select accelerometer

```swift
// Picks BMI160 or BMI270 based on module info read during connect()
if let acc = await device.makeAccelerometer(odrHz: 100, rangeG: 2) {
    // use acc with device.startStream(_:) or device.startLogging(_:)
}
```

### Log time anchor

During `connect()`, the SDK reads the board's current log tick and converts it to a wall-clock `Date`.
Downloaded `MWLoggedSample` values carry both a `.date` (wall clock) and a `.tickMs` (ms since device reset).

### Logger registry across reconnects

Logger subscriptions survive an unexpected BLE disconnect. On reconnect the device retains the same logger IDs.
Call `recoverLoggers(for:)` after reconnect if you didn't call `clearLog()` before disconnecting.

### Board state capture / restore

After a full `connect()` handshake you can persist the discovered module table and log time anchor, then skip re-discovery on subsequent reconnects when firmware / hardware revisions still match.

```swift
// After connect(), snapshot current state
guard let state = await device.captureBoardState() else { return }
let data = try state.encode()                           // JSON bytes
// …persist `data` to UserDefaults / SwiftData / file…

// Next session, before connect():
let restored = try MWBoardState.decode(data)
try await device.restoreBoardState(restored)           // throws if not disconnected
try await device.connect()                             // fast path — reuses cached modules
```

`MWBoardState` is `Codable`, `Sendable`, `Equatable`. Schema is versioned
(`MWBoardState.currentSchemaVersion`) so old caches are rejected safely.

### Anonymous signals (recover loggers the SDK didn't configure)

If the board still holds active loggers and data processors from a prior session — or from
another SDK — call `createAnonymousDataSignals()` to reconstruct `[MWAnonymousSignal]`
with canonical identifiers and typed decode closures, then download as normal.

```swift
try await device.connect()
let signals = try await device.createAnonymousDataSignals()
for sig in signals {
    print(sig.identifier, "→ loggers", sig.loggerIDs, "root", sig.rootModule)
}

// Each MWAnonymousSignal exposes:
//   .identifier   — canonical name (e.g. "acceleration", "angular-velocity:rms")
//   .rootModule   — underlying MWModule the chain reads from
//   .loggerIDs    — logger IDs whose chunks feed this signal (in order)
//   .decode(Data) throws -> [MWAnonymousSignal.Output]
//       Output = .cartesian | .scalar | .quaternion | .euler | .correctedCartesian
```

Wiring downloaded log entries into a signal's decode closure means grouping `RawLogEntry.rawData` bytes by `loggerIDs` and feeding each group as `Data` to `decode`. 
See `MWAnonymousSignalTests` for the exact byte layout per signal type.

Scale factors (accel / gyro range) are read from the live board at call time — if you change range afterward, call `createAnonymousDataSignals()` again.

### Logging a processor handle

The typed `startLogging(_:)` overload is sensor-shaped — it reads
`MWLoggable.logDataChunks` and parses samples back via `parseLogSample`.
For the output of a data-processor chain (throttle, RMS, accumulator, fuser, …)
the SDK exposes a key-based overload that takes the `MWProcessorHandle` directly
and lets you supply your own decoder at download time:

```swift
// Throttle 100 Hz Euler fusion down to 1 Hz, log 10 s, then download.
let euler = MWSensorFusionEuler(mode: .ndof, chip: .bmi270)
try await device.prepareSignalSource(euler)              // configure + start the source
let throttle = try await device.createProcessor(
    MWDataProcessor.Time(periodMs: 1000, mode: .absolute),
    source: MWSensorFusionEulerSignal()
)
let key = "euler-throttle-1hz"
try await device.startLogging(throttle, key: key)
try await Task.sleep(for: .seconds(10))
try await device.stopLogging(key: key)
try await device.teardownSignalSource(euler)            // stop + disable the source
_ = try await device.flushLogPage()                     // MMS only

let stream = try await device.downloadLogs(key: key) { data in
    try euler.parseLogSample(from: data)                // any (Data) throws -> S decoder
}
for try await progress in stream {
    print(progress.percentComplete, progress.data.count, "samples")
}
```

What's going on:

- `prepareSignalSource(_:)` / `teardownSignalSource(_:)` run the sensor's
  `configure → enable → start` (and the inverse) without subscribing to live
  output and without flipping the device into `.streaming`. This is the
  primitive you want whenever a sensor only feeds an on-board processor.
- `startLogging(_:key:)` issues one `[0x0B, 0x02, 0x09, 0x03, proc_id, packed]`
  subscribe per ≤4-byte chunk of the processor's output, registers the
  resulting logger IDs under `key`, and transitions the device to `.logging`.
- `downloadLogs(key:decode:)` reassembles entries by logger-ID order and
  hands each reconstructed payload to your decoder.

Sensor-fusion outputs are exposed as `MWSignal` values for use as processor
sources: `MWSensorFusionEulerSignal`, `MWSensorFusionQuaternionSignal`,
`MWSensorFusionGravitySignal`, `MWSensorFusionLinearAccelerationSignal`.

---

## Persistence (SwiftData)

The `MetaWearPersistence` library is a separate SwiftPM product that stores downloaded log sessions in SwiftData. It targets iOS 17 / macOS 14 (the same platforms as the core SDK) and ships its own test target (`MetaWearPersistenceTests`).

```swift
// Package.swift
.target(name: "MyApp", dependencies: ["MetaWear", "MetaWearPersistence"])
```

### One container per app, one store per call site

```swift
import MetaWear
import MetaWearPersistence

let container = try MWPersistenceStore.makeContainer()       // .makeContainer(inMemory: true) for previews / tests
let store     = MWPersistenceStore(modelContainer: container)
```

`MWPersistenceStore` is `@ModelActor` — a SwiftData-aware actor that pins a `ModelContext` to its serial executor. All store methods are `async`.

### Save a download session

```swift
let samples = try await collectAllSamples(from: device.downloadLogs(sensor))   // your code

let snapshot = try await store.saveSession(
    deviceID:     device.identifier,
    deviceInfo:   device.deviceInfo!,
    sensorKind:   CartesianFloat.persistenceKind,            // "cartesian"
    samples:      samples
)
print("Saved session", snapshot.id, "with \(snapshot.sampleCount) samples")
```

`MWSessionSnapshot` is a plain `Sendable` value — safe to hand to SwiftUI views or pass across actor boundaries. The matching `@Model` types (`MWSessionRecord`, `MWSampleRecord`) stay inside the store.

### Fetch / reconstruct / export

```swift
// All sessions for one device, newest first
let sessions = try await store.fetchSessions(deviceID: device.identifier)

// Rehydrate typed samples
let acceleration = try await store.fetchSamples(sessionID: snapshot.id, as: CartesianFloat.self)

// One-step CSV
let table = try await store.exportTable(sessionID: snapshot.id, as: CartesianFloat.self)
try table.writeCSV(to: URL(fileURLWithPath: "/tmp/session.csv"))
```

`fetchSamples` and `exportTable` validate that the session's `sensorKind` matches the requested type and throw `MWPersistenceError.kindMismatch` otherwise.

### Delete

```swift
try await store.deleteSession(id: snapshot.id)
try await store.deleteAllSessions(for: device.identifier)
try await store.deleteAll()
```

### Supported sample types

`MWPersistable` is a small protocol that pairs a `persistenceKind` discriminator with a flat `(f0, f1, f2, f3, accuracy)` packing. Retroactive conformances ship for every SDK sample type — `Float`, `Bool`, `CartesianFloat`, `CorrectedCartesianFloat`, `Quaternion`, `EulerAngles`. Adding a new sensor type means adding one extension block in `MWPersistableConformances.swift`.

---

## Data modes

### Streaming (live)

BLE delivers data as fast as the connection interval allows (~100 Hz practical max).
Packed mode sends 3 samples per BLE packet, tripling effective throughput for IMU sensors.

```
MetaWear → BLE notifications (packed, ~33/sec at 100Hz)
         → unpack 3 samples per notification
         → AsyncThrowingStream<Timestamped<Sample>, Error>
```

### Logging (on-device flash)

Sensors log to NAND flash at up to 800+ Hz independent of BLE. 
Download when done.

```
MetaWear flash → BLE burst download
              → parse 8-byte log entries (tick → epoch)
              → AsyncThrowingStream<Download<[MWLoggedSample<Sample>]>, Error>
```

Log entry format (8 bytes):
```
Byte 0:    (reset_uid[2:0] << 5) | log_id[4:0]
Bytes 1–3: tick (24-bit LE, ~1.465 ms/tick)
Bytes 4–7: raw sensor data (32-bit LE)
```

Tick math: `(48.0 / 32768.0) × 1000 ≈ 1.4648 ms/tick`

---

## BLE packet format

```
Byte 0:   module_id    (e.g. 0x03 = accelerometer)
Byte 1:   register_id  (| 0x80 for READ requests; response echoes this bit set)
Byte 2+:  payload      (little-endian)
```

Commands → `command` characteristic (`326A9001-…`), write-without-response.
Responses/notifications → `notify` characteristic (`326A9006-…`).
Macros use write-with-response.

Module IDs:

| ID | Module | ID | Module |
|---|---|---|---|
| 0x01 | Switch | 0x0C | Timer |
| 0x02 | LED | 0x0F | Macro |
| 0x03 | Accelerometer | 0x11 | Settings |
| 0x04 | Temperature | 0x12 | Barometer |
| 0x05 | GPIO | 0x13 | Gyroscope |
| 0x08 | Haptic | 0x15 | Magnetometer |
| 0x0A | Event | 0x19 | Sensor Fusion |
| 0x0B | Logging | 0xFE | Debug |

---

## Testing

### Unit tests (no hardware required)

```bash
swift test
# or target a specific suite:
swift test --filter MWTimer
swift test --filter MetaWearPersistenceTests
```

Three test targets ship with the package:

- **`MetaWearTests`** — ~896 `@Test` cases across 28 files. The full SDK surface, run against `MockBLETransport`. No hardware required.
- **`MetaWearPersistenceTests`** — 42 `@Test` cases across 3 files (`MWPersistableConformanceTests`, `MWPersistenceStoreTests`, `MWSessionExportTests`). In-memory SwiftData container — no hardware, no on-disk side effects.
- **`MetaWearHardwareTests`** — see [Hardware integration tests](#hardware-integration-tests). Real MetaWear required, run from the Xcode project.

`MetaWearTests` covers (one row per file, ordered roughly by dependency):

| Suite file                    | What it covers                                                                |
|-------------------------------|-------------------------------------------------------------------------------|
| `MWPacketParserTests`         | Raw byte → Swift type parsing for all sensors                                 |
| `MWModuleCommandTests`        | Every sensor/module builds correct command bytes                              |
| `MWAccelerometerBMI160Tests`  | BMI160 config bytes, parse vectors, step counter / detector commands          |
| `MWLEDTests`                  | LED pattern bytes, preset validation                                          |
| `MWSwitchHapticTests`         | Switch stream, haptic pulse bytes                                             |
| `MWDebugTemperatureTests`     | Debug command bytes, temperature read                                         |
| `MWProtocolLayerTests`        | Notification routing, module discovery, concurrent reads                      |
| `MetaWearDeviceTests`         | State machine, connect/disconnect, streaming/logging guards                   |
| `MWFactoryResetTests`         | factoryReset() seven-write sequence, post-reset state transition              |
| `MWGenericReadPollTests`      | Generic `device.read(_:)` and `device.poll(_:every:)` for `MWReadable` / `MWPollable` |
| `MWMiscReadablesTests`        | `MWLogLength`, `MWLastResetTime`, `MWMACAddress` shape + parsing, `MWPollable` conformances |
| `MWLoggingTests`              | startLogging commands, RawLogEntry parsing, chunk config, clearLog            |
| `MWLogFinishingTests`         | Log time anchor, registry persistence, anonymous logger recovery              |
| `MWGPIOLEDTests`              | GPIO output commands, one-shot reads, pin-change stream, multi-channel LED    |
| `MWTimerTests`                | Timer create/start/stop/remove, tick stream, period encoding                  |
| `MWEventTests`                | Event source constructors, createEvent command format, remove                 |
| `MWMacroTests`                | recordMacro, ADD_PARTIAL for long commands, execute, erase                    |
| `MWSerialTests`               | I2C / SPI write + read command bytes, response parsing                        |
| `MWiBeaconTests`              | iBeacon UUID / major / minor / TX power / period / enable bytes               |
| `MWDataProcessorTests`        | ADD command bytes and config bits for all 17 processor types                  |
| `MWDataTableTests`            | CSV table construction and export for streamed + logged samples               |
| `MWModelTests`                | MetaWear model detection from firmware/hardware revision strings              |
| `MWSensorFusionLoggingTests`  | Sensor fusion log configuration, calibration read, download                   |
| `MWAmbientLightTests`         | LTR329 config bytes, lux conversion                                           |
| `MWHumidityTests`             | BME280 humidity read command + oversampling config                            |
| `MWBoardStateTests`           | Capture / restore of discovered modules, Codable round-trip                   |
| `MWAnonymousSignalTests`      | Reconstruction of unknown loggers from board state, chunk partitioning        |
| `MWProductionGapTests`        | Concurrent reads, multi-sensor streaming, reconnect, device-name validation   |

### MockBLETransport

Inject notifications and inspect written commands in tests:

```swift
let transport = MockBLETransport()
let device = MetaWearDevice(identifier: UUID(), transport: transport)

// Inject a response to a read command
await transport.inject(notification: Data([0x0C, 0x82, 0x01]), to: MWUUIDs.notify)

// Inspect what the device wrote
let cmds = await transport.writtenCommands  // [Data]
```

### Hardware integration tests

Hardware tests require a real MetaWear nearby. They live in a separate Xcode project that provides a proper macOS app test host — required for CoreBluetooth to work with macOS privacy permissions.

#### Open the project:

```
Tests/IntegrationTests/MetaWearTestHost.xcodeproj
```

First time:
1. Open the project in Xcode
2. In **Signing & Capabilities** for both targets, set your **Development Team**
3. Run the `MetaWearHardwareTests` scheme (⌘U)

macOS will prompt for Bluetooth permission the first time — grant it once and it's remembered.

If no device is found within the 10-second scan window, all hardware tests **fail** with a clear error message — they are not intended to be run without hardware.

Modules that are not present on the connected board (e.g. barometer on a board without one) are skipped gracefully within each test.

Hardware test suites — 36 `@Suite` blocks across 26 files:

| Suite                                         | What it covers                                                                                                              |
|-----------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| `Bluetooth — Smoke`                           | Bluetooth hardware present and powered on, MetaWear discoverable                                                            |
| `Hardware — Connectivity`                     | Device info, battery, module presence                                                                                       |
| `Hardware — Device Connection Lifecycle`      | connect / disconnect / reconnect, state transitions, scanner-vended pending-connect cancellation                            |
| `Hardware — LED`                              | Single-channel patterns (blink, breathe, solid, flash), stop / clear                                                        |
| `Hardware — Haptic`                           | Motor pulse, max duty cycle, buzzer pulse                                                                                   |
| `Hardware — Accelerometer`                    | High-level streaming smoke for the auto-detected accelerometer (ODR snap, range, packed default)                            |
| `BMI160 — Acceleration Data`                  | BMI160 raw register: per-config wire bytes, parse vectors, range / ODR encoding                                             |
| `BMI160 — Packed Acceleration Data`           | BMI160 packed register: 3-sample-per-packet, sample-count over a fixed window                                               |
| `BMI270 — Acceleration Data`                  | BMI270 raw register: parity with the BMI160 cases                                                                           |
| `BMI270 — Packed Acceleration Data`           | BMI270 packed register: parity with the BMI160 packed cases                                                                 |
| `BMI160 — Gyroscope Data`                     | BMI160 raw gyro register, range / ODR encoding                                                                              |
| `BMI160 — Packed Gyroscope Data`              | BMI160 packed gyro register, sample-count over a fixed window                                                               |
| `BMI270 — Gyroscope Data`                     | BMI270 raw gyro register: parity with the BMI160 cases                                                                      |
| `BMI270 — Packed Gyroscope Data`              | BMI270 packed gyro register: parity with the BMI160 packed cases                                                            |
| `Magnetometer — Magnetic-Field Data`          | BMM150 raw register, preset-driven ODR (skips on boards without BMM150)                                                     |
| `Magnetometer — Packed Magnetic-Field Data`   | BMM150 packed register                                                                                                      |
| `Magnetometer — Suspend`                      | Suspend / wakeup register, post-resume sample shape                                                                         |
| `Hardware — Environment Sensors`              | Temperature (NRF die + BMP280 + preset thermistor, dynamic channel lookup), barometer pressure, altimeter, humidity (skip on non-BME) |
| `Sensor Fusion — Quaternion`                  | Quaternion unit magnitude across NDoF / IMU+ modes                                                                          |
| `Sensor Fusion — Euler Angles`                | Heading / pitch / roll / yaw range + finite                                                                                 |
| `Sensor Fusion — Gravity`                     | Gravity vector ~ 1 g at rest                                                                                                |
| `Sensor Fusion — Linear Acceleration`         | Linear acceleration ~ 0 at rest                                                                                             |
| `Sensor Fusion — Calibration`                 | Calibration state read on a running fusion stream                                                                           |
| `Hardware — GPIO`                             | Digital read with pull-up / pull-down, analog ADC + absolute, pin-change stream                                             |
| `Hardware — Switch`                           | Stream lifecycle, press / release events in a listen window                                                                 |
| `Hardware — Settings`                         | Device name set / restore (verified via rescan of advertised name), TX power (verified via RSSI delta), connection parameters, start advertising |
| `Hardware — iBeacon`                          | Enable / disable full iBeacon profile (UUID, major / minor, RX / TX power, period)                                          |
| `Hardware — Events`                           | removeAll smoke; button → LED event; processor chain → alternating LED on odd / even presses                                |
| `Hardware — Commands`                         | powerDownSensors equivalent; LED variants (purple breathe, orange flash, green fast / blue infrequent / red raised-low blink, yellow solid → off) |
| `Hardware — Macro`                            | Record + execute, multi-command body, erase all                                                                             |
| `Hardware — Reads`                            | Generic `device.read(_:)` round-trip for every `MWReadable` (temperature channels, battery, last reset time, log length, humidity, MAC) |
| `Hardware — Streams (legacy parity)`          | Legacy SDK stream-test parity (ambient light, charging-status poll, motion / orientation / step detectors, sensor-fusion sweep) |
| `Hardware — Logging`                          | Accelerometer + gyroscope log / download for BMI160 + BMI270, clearLog                                                      |
| `Sensor Fusion — Logging`                     | Sensor fusion log / download (quaternion, Euler angles, gravity, linear acceleration)                                       |
| `Hardware — Factory Reset`                    | factoryReset advances reset UID, restores defaults, reconnect after reboot, post-reset flash state cleared                  |
| `Hardware — Serial (I2C / SPI)`               | Module presence, I2C write, I2C read (WHO_AM_I probe), SPI write, SPI read                                                  |

---

## Mac demo (real hardware)

A CLI that scans, connects, reads device info and battery, flashes the LED, fires the haptic motor, and streams the accelerometer for 5 seconds:

```bash
swift run MetaWearDemo
```

On first run macOS will prompt for Bluetooth permission — grant it once and it's remembered.

#### What the demo does:

1. Scans 8 seconds and lists found devices
2. Connects to the first device found
3. Prints firmware, model, serial, hardware revision
4. Reads battery charge (%) and voltage (mV)
5. Flashes the green LED (visual confirmation)
6. Fires the haptic motor (300 ms)
7. Streams the accelerometer at 100 Hz for 5 seconds, printing every 20th sample
8. Reports total sample count and effective Hz
9. Disconnects cleanly

---

## What's not yet implemented

### Known small SDK gaps (deferred from legacy parity)

| Gap | Blocks | Workaround |
|---|---|---|
| `MWChargingStatus` not exposed as `MWLoggable` | Persisting charge transitions to flash | `device.poll(MWSettings.ReadChargeStatus(), every:)` covers the live-observation case. |

> Resolved: macros can now embed `createEvent(...)` via the closure-form
> `recordMacro(executeOnBoot:_:)` (see [Macros](#macros)). The previously-deferred
> legacy test `test_MacroEventRecording_LEDFlashOnButtonUpDown` ports cleanly to
> `EventTests.macro_buttonChanged_flashesLED_persistsViaMacro`.

> Resolved: `startLogging` now accepts an `MWProcessorHandle` via the
> `(handle:key:)` overload (see [Logging a processor handle](#logging-a-processor-handle)).
> The previously-deferred legacy tests `test_EventTimeThrottling_SlowSensorFusion_Download_*`
> port to `EventTests.throttledFusion_logsAtOneHz_downloads`.
