# MetaWear Swift SDK

A clean-room Swift 6 implementation of the MetaWear protocol.

## Requirements

| Requirement | Version |
|-------------|---------|
| Swift | 6.0+ |
| iOS | 17+ |
| macOS | 14+ |
| Xcode | 16+ |

---

## Quick Start

### Add the package

In Xcode: **File → Add Package Dependencies**, enter the repo URL.

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
let stream = try await device.stream(sensor)

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

### Fire the haptic motor

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
├──────────────────┬───────────────────────────┤
│  MWCentralManager│ CoreBluetoothPeripheral   │
│  (shared)        │ Transport (per device)    │
├──────────────────┴───────────────────────────┤
│  MockBLETransport (unit tests, no hardware)  │
└──────────────────────────────────────────────┘
```

### Key design decisions

| Concern | Choice | Why |
|---|---|---|
| Async sequences | `AsyncThrowingStream` | Errors propagate on BLE drop; no Combine dependency |
| Thread safety | `actor` | Compiler-enforced, Swift 6 native |
| BLE wrapper | Custom `CoreBluetoothTransport` | Third-party libs use Combine for notifications |
| Observation | `@Observable` | SwiftUI-native, less boilerplate than `ObservableObject` |

---

## Layer-by-layer breakdown

### MetaWearScanner

`@Observable @MainActor` class — safe to bind directly to SwiftUI views. Owns a single `MWCentralManager` (which owns the `CBCentralManager`). Each discovered peripheral gets its own isolated `CoreBluetoothPeripheralTransport` and `MetaWearDevice`.

```swift
public final class MetaWearScanner {
    public private(set) var discoveredDevices: [UUID: MetaWearDevice]
    public private(set) var isScanning: Bool

    public func startScan()
    public func stopScan()
}
```

### MetaWearDevice

`actor` — all state is actor-isolated, thread-safe by default. Enforces the device state machine at compile time; invalid transitions throw `MWError.invalidState`.

```
.disconnected → .idle → .streaming
                      → .logging
                      → .downloading(progress:)
```

Key methods:
```swift
public func connect() async throws
public func disconnect() async throws

public func stream<S: MWStreamable>(_ sensor: S, usePacked: Bool = true)
    async throws -> AsyncThrowingStream<Timestamped<S.Sample>, Error>
public func stopStreaming<S: MWStreamable>(_ sensor: S) async throws

public func startLogging<L: MWLoggable>(_ loggable: L) async throws
public func stopLogging<L: MWLoggable>(_ loggable: L) async throws
public func downloadLogs() async throws -> AsyncThrowingStream<Download<[RawLogEntry]>, Error>
public func downloadLogs<L: MWLoggable>(_ loggable: L)
    async throws -> AsyncThrowingStream<Download<[MWLoggedSample<L.Sample>]>, Error>
public func clearLog() async throws
@discardableResult public func flushLogPage() async throws -> Bool

public func readBattery() async throws -> BatteryState
public func read<R: MWReadable>(_ readable: R) async throws -> Timestamped<R.Sample>
public func poll<P: MWPollable>(_ readable: P, every: Duration)
    -> AsyncThrowingStream<Timestamped<P.Sample>, Error>
public func send(_ command: any MWCommand) async throws
public func send(_ sequence: any MWCommandSequence) async throws
```

### BLE transport split

The single `CBCentralManager` is shared across all devices; per-peripheral state is isolated:

| Type | Role |
|---|---|
| `MWCentralManager` | Owns `CBCentralManager`. Routes `didConnect`/`didDisconnect` to the correct device transport by UUID. Internal. |
| `CoreBluetoothPeripheralTransport` | One per device. Owns `CBPeripheral`, characteristics, read/write continuations, notify streams, write queue. Implements `BLETransport`. Internal. |
| `MockBLETransport` | Public in-memory transport for unit tests. Inject notifications with `inject(notification:to:)`. No hardware required. |

Both real transports use the `nonisolated` delegate pattern — CoreBluetooth callbacks hop back into the actor via `Task { await self.handle…() }`.

### MWProtocolLayer

Routes raw BLE notification bytes to the right handler by `(module_id, register_id)` key.

- **Read responses** (`register | 0x80` bit set) → resume the parked `CheckedContinuation`
- **Unsolicited notifications** → yield to the subscribed `AsyncThrowingStream.Continuation`
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

`device.send(_:)` is overloaded for both commands and sequences — a single
call site regardless of whether the action emits one or many writes.

### Generic read and poll

Any `MWReadable` works with the generic `device.read(_:)` helper; any
`MWPollable` also works with `device.poll(_:every:)` which returns an
`AsyncThrowingStream`:

```swift
let humidity = try await device.read(MWHumidity())          // Timestamped<Float>
let entries  = try await device.read(MWLogLength())         // Timestamped<UInt32>
let mac      = try await device.read(MWMACAddress())        // Timestamped<String>
let resetAt  = try await device.read(MWLastResetTime())     // Timestamped<Date>

for try await sample in await device.poll(MWSettings.ReadBatteryState(),
                                          every: .seconds(30)) {
    updateBatteryUI(sample.value)
}
```

`poll` reads the sensor, yields the timestamped sample, sleeps for the given
`Duration`, and repeats. Cancelling the enclosing `Task` or breaking out of
the `for await` loop stops the loop and ends the stream.

Built-in `MWPollable` conformers: `MWLogLength`, `MWLastResetTime`,
`MWMACAddress`, `MWSettings.ReadBatteryState`, `MWSettings.ReadPowerStatus`,
`MWSettings.ReadChargeStatus`, `MWHumidity`, `MWBarometerPressureRead`,
`MWThermometer`, `MWSensorFusionCalibrationState`.

---

## Supported sensors and modules

### Accelerometer

```swift
// BMI160 (MetaWear R/C/RPro/CPro, MetaMotion R/C)
let acc = MWAccelerometerBMI160(odr: .hz100, range: .g2)
// ODR: .hz0_78 … .hz1600
// Range: .g2, .g4, .g8, .g16

// BMI270 (MetaMotion S)
let acc = MWAccelerometerBMI270(odr: .hz100, range: .g2)
```

Packed data (3 samples per BLE packet) is used automatically when `usePacked: true` (default). Scale factors (LSB/g): ±2g = 16384, ±4g = 8192, ±8g = 4096, ±16g = 2048.

### Gyroscope

```swift
let gyro = MWGyroscopeBMI160(odr: .hz100, range: .dps2000)
// ODR: .hz25 … .hz3200
// Range: .dps125, .dps250, .dps500, .dps1000, .dps2000

let gyro = MWGyroscopeBMI270(odr: .hz100, range: .dps2000)
```

### Bosch motion detectors (accelerometer interrupts)

Orientation, any-motion, and tap interrupts are generated on-chip by the BMI160 / BMI270.
Configure + enable the detector, then subscribe to the accelerometer interrupt register to
receive decoded events.

```swift
// Orientation — fires when the device rotates through one of 8 states (register 0x11)
try await device.send(MWAccelerometerBosch.EnableOrientation())
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

BMI270-only features exposed via `MWAccelerometerBMI270Features`. `Configure…`
and `SetDownsampling` conform to `MWCommand`; the `Enable…` / `Disable…`
pairs (which emit both `FEATURE_INTERRUPT_ENABLE` and `FEATURE_ENABLE` writes)
conform to `MWCommandSequence`. Both ship through the same `device.send(_:)`
entry point.

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
try await device.send(
    MWAccelerometerBMI270Features.ConfigureNoMotion(
        duration: 5, threshold: 0xAA,
        selectX: true, selectY: true, selectZ: true
    )
)
try await device.send(MWAccelerometerBMI270Features.EnableNoMotion())

// FIFO downsampling (register 0x11) — reduce logged sample rate per axis-group
try await device.send(
    MWAccelerometerBMI270Features.SetDownsampling(
        gyroOrdinal: 2, gyroFilterData: true,
        accOrdinal: 2,  accFilterData: true
    )
)
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
let stream = try await device.stream(als)
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
let stream = try await device.stream(signal)
for try await sample in stream {
    print("pin \(sample.value.pin) → \(sample.value.isHigh ? "high" : "low")")
}
```

### Switch / Button (module 0x01)

```swift
let stream = try await device.stream(MWSwitch())
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
    action: MWEventAction(command: MWLED.Play())
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

**Source → destination data slicing (`MWEventDataToken`)**

Optional instruction appended to the ENTRY command that tells the firmware to
copy `length` bytes starting at `sourceOffset` of the source signal's payload
into the destination command's params starting at `destOffset` when the event
fires. Without a token the destination params are written as-is.

```swift
// Route 4 bytes from source offset 2 into destination offset 3
let event = try await device.createEvent(
    source: .timerFired(timer),
    action: action,
    dataToken: MWEventDataToken(length: 4, sourceOffset: 2, destOffset: 3)
)
// Constraints: length 1…7 (3 bits), sourceOffset 0…15 (4 bits), destOffset any UInt8
```

### Macro (module 0x0F)

Record a sequence of commands into device flash. Execute manually or automatically on every power-on.

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

### Serial Passthrough — I2C / SPI (module 0x0D)

Communicate with external sensors or ICs wired to the MetaWear's I2C or SPI bus.

**I2C write**

```swift
// Write 0x00 to register 0x6B of the device at I2C address 0x68 (e.g. wake an MPU-6050)
try await device.send(MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0x00]))
```

**I2C read**

```swift
// Read 1 byte from register 0x75 (WHO_AM_I) of the device at 0x68
let bytes = try await device.i2cRead(deviceAddress: 0x68, registerAddress: 0x75, length: 1)
print("WHO_AM_I:", bytes.map { String(format: "0x%02X", $0) })
```

**SPI write**

```swift
// Send 0x9F (READ_ID) over SPI at 1 MHz, mode 3, MSB-first
try await device.send(MWSerial.SPIWrite(
    slaveSelect: 0,
    clock: .f1MHz,
    mode: .mode3,
    data: [0x9F]
))
```

**SPI read**

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

**Create a processor:**

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

**Stream a processor's output:**

```swift
let stream = try await device.streamProcessor(threshHandle)
for try await packet in stream {
    // packet = [0x09, 0x03, proc_id, data_bytes...]
    let value = Int32(littleEndian: packet.dropFirst(3).withUnsafeBytes { $0.load(as: Int32.self) })
    print("threshold crossed:", value > 0 ? "above" : "below")
}
```

**Stop and remove:**

```swift
try await device.stopStreamingProcessor(threshHandle)
try await device.removeProcessor(threshHandle)

// Remove everything:
try await device.removeAllProcessors()
```

**Available processor types:**

| Type | Class | Output |
|------|-------|--------|
| Passthrough | `MWDataProcessor.Passthrough` | Gate — pass all / conditional / count |
| Accumulator | `MWDataProcessor.Accumulator` | Running sum |
| Counter | `MWDataProcessor.Counter` | Event count |
| Average (LPF) | `MWDataProcessor.Average` | Rolling average |
| RMS combiner | `MWDataProcessor.RMS` | Scalar magnitude (root-mean-square) |
| RSS combiner | `MWDataProcessor.RSS` | Scalar magnitude (root-sum-square) |
| Time delay | `MWDataProcessor.Time` | Rate-limited samples (absolute or differential) |
| Math | `MWDataProcessor.Math` | Arithmetic transform (+ – × ÷ %, shifts, abs, √, etc.) |
| Sample delay | `MWDataProcessor.Sample` | Burst of N buffered samples |
| Comparator | `MWDataProcessor.Comparator` | Filter by compare against a reference |
| Threshold | `MWDataProcessor.Threshold` | Crossing events (absolute or binary ±1) |
| Delta | `MWDataProcessor.Delta` | Emit when input changes by ≥ magnitude |
| Pulse | `MWDataProcessor.Pulse` | Detect pulses → emit width / area / peak / on-detect |
| Buffer | `MWDataProcessor.Buffer` | Hold last sample (read on demand or fused) |
| Packer | `MWDataProcessor.Packer` | Pack N samples per BLE packet |
| Accounter | `MWDataProcessor.Accounter` | Prepend timestamp or packet counter |
| Fuser | `MWDataProcessor.Fuser` | Combine latest primary + buffered secondaries |

**Chaining** — `MWProcessorHandle` conforms to `MWSignal`, so any processor's output can feed
directly into the next `createProcessor` call. The handle carries the board-assigned ID plus
the output channel count, channel width, and signedness so the next stage's config bytes are
computed correctly without any manual bookkeeping.

---

### Settings (module 0x11)

```swift
try await device.send(MWSettings.SetDeviceName("MySensor"))                  // max 26 ASCII bytes (truncates)
try await device.send(MWSettings.SetDeviceName(validating: "MySensor"))      // throws on invalid chars / length
try await device.send(MWSettings.SetTXPower(.minus4))        // BLE TX power
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

MetaMotion S boards (logging revision ≥ 3) buffer the final partial flash page
in RAM. Call `flushLogPage()` to force that buffer to flash before downloading
— without it, the last few seconds of samples may be missing from the download.
On older boards the call is a no-op and returns `false`.

```swift
try await device.stopLogging(sensor)
let flushed = try await device.flushLogPage()   // true on MMS, false elsewhere
let stream  = try await device.downloadLogs(sensor)
```

### CSV export

Any array of logged or streamed samples can be converted to a `MWDataTable` and exported as CSV. All sensor sample types (`CartesianFloat`, `Quaternion`, `EulerAngles`, `Float`, `Bool`, `CorrectedCartesianFloat`) conform to `MWDataConvertible` automatically.

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
    // use acc with device.stream(_:) or device.startLogging(_:)
}
```

### Log time anchor

During `connect()`, the SDK reads the board's current log tick and converts it to a wall-clock `Date`. Downloaded `MWLoggedSample` values carry both a `.date` (wall clock) and a `.tickMs` (ms since device reset).

### Logger registry across reconnects

Logger subscriptions survive an unexpected BLE disconnect. On reconnect the device retains the same logger IDs. Call `recoverLoggers(for:)` after reconnect if you didn't call `clearLog()` before disconnecting.

### Board state capture / restore

After a full `connect()` handshake you can persist the discovered module table and log time
anchor, then skip re-discovery on subsequent reconnects when firmware / hardware revisions
still match.

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

Wiring downloaded log entries into a signal's decode closure means grouping
`RawLogEntry.rawData` bytes by `loggerIDs` and feeding each group as `Data` to
`decode`. See `MWAnonymousSignalTests` for the exact byte layout per signal type.

Scale factors (accel / gyro range) are read from the live board at call time — if you
change range afterward, call `createAnonymousDataSignals()` again.

---

## Data modes

### Streaming (live)

BLE delivers data as fast as the connection interval allows (~100 Hz practical max). Packed mode sends 3 samples per BLE packet, tripling effective throughput for IMU sensors.

```
MetaWear → BLE notifications (packed, ~33/sec at 100Hz)
         → unpack 3 samples per notification
         → AsyncThrowingStream<Timestamped<Sample>, Error>
```

### Logging (on-device flash)

Sensors log to NAND flash at up to 800+ Hz independent of BLE. Download when done.

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
```

~795 `@Test` cases across 24 test files — all run without hardware using `MockBLETransport`:

| Suite file | What it covers |
|---|---|
| `MWPacketParserTests` | Raw byte → Swift type parsing for all sensors |
| `MWModuleCommandTests` | Every sensor/module builds correct command bytes |
| `MWLEDTests` | LED pattern bytes, preset validation |
| `MWSwitchHapticTests` | Switch stream, haptic pulse bytes |
| `MWDebugTemperatureTests` | Debug command bytes, temperature read |
| `MWProtocolLayerTests` | Notification routing, module discovery, concurrent reads |
| `MetaWearDeviceTests` | State machine, connect/disconnect, streaming/logging guards |
| `MWLoggingTests` | startLogging commands, RawLogEntry parsing, chunk config, clearLog |
| `MWLogFinishingTests` | Log time anchor, registry persistence, anonymous logger recovery |
| `MWGPIOLEDTests` | GPIO output commands, one-shot reads, pin-change stream, multi-channel LED |
| `MWTimerTests` | Timer create/start/stop/remove, tick stream, period encoding |
| `MWEventTests` | Event source constructors, createEvent command format, remove |
| `MWMacroTests` | recordMacro, ADD_PARTIAL for long commands, execute, erase |
| `MWSerialTests` | I2C / SPI write + read command bytes, response parsing |
| `MWiBeaconTests` | iBeacon UUID / major / minor / TX power / period / enable bytes |
| `MWDataProcessorTests` | ADD command bytes and config bits for all 17 processor types |
| `MWDataTableTests` | CSV table construction and export for streamed + logged samples |
| `MWModelTests` | MetaWear model detection from firmware/hardware revision strings |
| `MWSensorFusionLoggingTests` | Sensor fusion log configuration, calibration read, download |
| `MWAmbientLightTests` | LTR329 config bytes, lux conversion |
| `MWHumidityTests` | BME280 humidity read command + oversampling config |
| `MWBoardStateTests` | Capture / restore of discovered modules, Codable round-trip |
| `MWAnonymousSignalTests` | Reconstruction of unknown loggers from board state, chunk partitioning |
| `MWProductionGapTests` | Concurrent reads, multi-sensor streaming, reconnect, device-name validation |

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

**Open the project:**
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

Hardware test suites:

| Suite | What it covers |
|---|---|
| `Bluetooth — Smoke` | Bluetooth hardware present and powered on, MetaWear discoverable |
| `Hardware — Connectivity` | device info, battery, module presence, reconnect |
| `Hardware — LED & Haptic` | green/red/blue flash, breathe, solid white, multi-channel, clear pattern, motor + buzzer haptic |
| `Hardware — Sensor Streaming` | accelerometer (BMI160 + BMI270) sample count + magnitude, gyroscope (BMI160 + BMI270), switch stream |
| `Hardware — Environment Sensors` | temperature (NRF die + Bosch), barometer pressure, altimeter, magnetometer |
| `Hardware — Sensor Fusion` | quaternion unit magnitude, Euler angle range, gravity vector ~1 g, linear acceleration ~0 at rest |
| `Hardware — GPIO & Settings` | digital read (pull-up/down), analog ADC + absolute, pin-change stream, device name, TX power, connection parameters |
| `Hardware — Timer & Event` | tick stream, stop prevents ticks, event → LED binding |
| `Hardware — Macro` | record + execute, multi-command, erase all |
| `Hardware — Logging` | accelerometer + gyroscope log/download for BMI160 and BMI270, clearLog |
| `Hardware — Serial (I2C / SPI)` | module presence, I2C write, I2C read (WHO_AM_I probe), SPI write, SPI read |

---

## Mac demo (real hardware)

A CLI that scans, connects, reads device info and battery, flashes the LED, fires the haptic motor, and streams the accelerometer for 5 seconds:

```bash
swift run MetaWearDemo
```

On first run macOS will prompt for Bluetooth permission — grant it once and it's remembered.

**What the demo does:**
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

## Protocol reference

Full byte-level specification — every module opcode, register, command byte layout, config bit-field, response format, and scale factor:

```
/Users/kasso/Documents/MetaWear-API/docs/protocol-reference.md
```

Extracted from [MetaWear-SDK-Cpp](https://github.com/mbientlab/MetaWear-SDK-Cpp). Run `mkdocs serve` in that directory to browse as a formatted site.

---

## What's not yet implemented

| Feature | Notes |
|---|---|
| SwiftUI app target | Scan list, connect screen, live Swift Charts graph |
| SwiftData persistence | Store downloaded log entries across sessions |
| DFU (firmware update) | Requires Nordic DFU library |
