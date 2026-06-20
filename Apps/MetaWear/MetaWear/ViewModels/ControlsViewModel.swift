import Foundation
import Observation
import MetaWear

/// Presentation model for quick device controls.
///
/// Keeps UI-editable command settings for LED and haptic actions, plus the
/// latest one-shot read values for temperature, pressure, and ambient light.
@Observable
@MainActor
final class ControlsViewModel {
    private let device: MetaWearDevice
    var lastError: AppError?

    var ledColor: MWLED.Color = .green
    var ledPattern: MWLEDPattern = .blink
    var motorDuty: UInt8 = 100
    var motorPulseMs: UInt16 = 500

    /// Latest one-shot sensor readings. `nil` until the user taps the
    /// corresponding "Read" button. Each one is set by its own async
    /// helper below and rendered in the Controls "Quick Reads" section.
    var temperatureC: Float?
    var pressurePa: Float?
    var ambientLightLux: Float?
    /// Per-sensor "currently reading" flags so the button can swap to a
    /// spinner without blocking the others. (BLE writes serialise on the
    /// transport actor anyway, but the UI can fire them in parallel.)
    var isReadingTemperature = false
    var isReadingPressure = false
    var isReadingLight = false

    var motorDutyPercent: Int {
        get { Int(motorDuty) }
        set { motorDuty = UInt8(clamping: newValue) }
    }

    var motorPulseMilliseconds: Int {
        get { Int(motorPulseMs) }
        set { motorPulseMs = UInt16(clamping: newValue) }
    }

    init(device: MetaWearDevice) {
        self.device = device
    }

    func playLED() async {
        do {
            try await device.send(MWLED.SetPattern(color: ledColor, pattern: ledPattern))
            try await device.send(MWLED.Play())
        } catch {
            lastError = AppError(error: error)
        }
    }

    func stopLED() async {
        do {
            try await device.send(MWLED.Stop())
        } catch {
            lastError = AppError(error: error)
        }
    }

    func pulseMotor() async {
        do {
            try await device.send(MWHaptic.motor(dutyCycle: motorDuty, pulseWidth: motorPulseMs))
        } catch {
            lastError = AppError(error: error)
        }
    }

    func pulseBuzzer() async {
        do {
            try await device.send(MWHaptic.buzzer(pulseWidth: motorPulseMs))
        } catch {
            lastError = AppError(error: error)
        }
    }

    // MARK: - One-shot reads

    /// Read the on-die NRF thermistor (channel 0 — present on every
    /// MetaWear board, no GPIO setup required). °C.
    func readTemperature() async {
        isReadingTemperature = true
        defer { isReadingTemperature = false }
        do {
            let sample = try await device.read(MWThermometer(channel: 0))
            temperatureC = sample.value
        } catch {
            lastError = AppError(error: error)
        }
    }

    /// One-shot BMP280/BME280 pressure read. Returns Pa from the SDK;
    /// the view divides by 100 for hPa display.
    func readPressure() async {
        isReadingPressure = true
        defer { isReadingPressure = false }
        do {
            let sample = try await device.read(MWBarometerPressureRead())
            pressurePa = sample.value
        } catch {
            lastError = AppError(error: error)
        }
    }

    /// One-shot ambient-light read. The LTR329 only exposes a streaming
    /// register, so we briefly start the stream, take the first valid
    /// sample, and tear it down. Defaults:
    ///   - `gain: .x1` — widest range (1 lux to 64 klux), fine for
    ///     general "what's the light level right now" checks.
    ///   - `measurementRate: .ms100` — fastest valid rate, so warm-up
    ///     + first real sample land inside ~200 ms.
    /// The sensor returns a zero for its very first sample after enable
    /// (it needs one integration cycle to produce real data); we skip
    /// leading zeros up to a small budget instead of reporting that as
    /// "0 lux". After ~10 samples (≈1 s) we give up and return whatever
    /// we last saw — a genuinely dark room reads ~0 anyway.
    func readAmbientLight() async {
        isReadingLight = true
        defer { isReadingLight = false }
        let sensor = MWAmbientLight(gain: .x1,
                                    integrationTime: .ms100,
                                    measurementRate: .ms100)
        do {
            let stream = try await device.startStream(sensor)
            // Once the stream has started it MUST be torn down on every exit,
            // including the throwing one (mid-read disconnect / malformed
            // packet). `defer` can't await, so use an inner do/catch and tear
            // down unconditionally after it — otherwise the LTR329 stays
            // enabled and its active-stream entry blocks every later read.
            do {
                var lastRaw: UInt32 = 0
                var seen = 0
                for try await sample in stream {
                    lastRaw = sample.value
                    seen += 1
                    if sample.value > 0 || seen >= 10 { break }
                }
                ambientLightLux = Float(lastRaw) / 1000
            } catch {
                lastError = AppError(error: error)
            }
            try? await device.stopStreaming(sensor)
        } catch {
            // `startStream` itself failed — nothing was enabled to tear down.
            lastError = AppError(error: error)
        }
    }
}
