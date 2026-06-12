import Testing
import MetaWear
import Foundation

// MARK: - On-device events — bind sensor signals to commands on real hardware

@Suite("Hardware — Events", .serialized)
struct EventTests {

    // MARK: - removeAllEvents smoke
    //
    // The legacy `testRemoveEvents_NoFailure` just sent the C++ "reset
    // activities" command (a bundled removeAllEvents + removeAllProcessors +
    // removeAllMacros + clearLog). We send the equivalent Swift calls
    // separately and rely on each one not throwing — on a fresh board there's
    // nothing to remove, but the firmware accepts the command anyway.

    @Test @MainActor
    func events_removeAll_succeeds() async throws {
        try await withConnectedDevice { device in
            // None of these should throw on a board with no prior bindings.
            try await device.removeAllEvents()
            try await device.removeAllProcessors()
            try await device.eraseAllMacros()
            try await device.clearLog()
            print("\n  ✓ removeAllEvents / removeAllProcessors / eraseAllMacros / clearLog all succeeded\n")
        }
    }

    // MARK: - Button → LED event binding
    //
    // Pre-configures a green flash pattern, then binds an event so each button
    // transition (press OR release) re-plays the pattern. This is the smoke
    // that legacy tests `MechanicalButtonUp` and `MechanicalButtonDown` were
    // exercising with two different colors. We use a single color here since
    // the new SDK's `.buttonChanged()` source fires on both edges.
    //
    // The test is visual on real hardware — operator should observe the LED
    // flash green when the board's push button is tapped. The 5 s sleep gives
    // a window for that interaction.

    @Test @MainActor
    func event_buttonChanged_flashesLED() async throws {
        try await withConnectedDevice { device in
            // Start clean — leftover events / macros / processors from a prior
            // run would consume firmware slots and could re-fire the LED at
            // unexpected moments during this test's wait window.
            try await resetBoardState(device)

            // Pre-configure the pattern. Play() triggered by the event re-runs it.
            try await device.send(MWLED.SetPattern(color: .green, .flash))

            let event = try await device.createEvent(
                source: .buttonChanged(),
                action: MWEventAction(command: MWLED.Play())
            )
            print("""

              Event \(event.id) bound: button-change → LED green flash
              ▶ Tap the board's button now — LED should flash green on each press / release
              ▶ Waiting 5 s …

            """)
            try await Task.sleep(for: .seconds(5))

            // Cleanup
            try await device.removeAllEvents()
            try await device.send(MWLED.Stop(clearPattern: true))
        }
    }

    // MARK: - Counter / Math / Comparator chain → alternating LED colors
    //
    // Ports `test_MacroEventRecording_OddAndEvenButtonPressesTriggerLEDFlash`
    // without the surrounding macro wrapper (see top-of-file comment).
    //
    // Wiring (board side, no host involvement once set up):
    //
    //   [Switch register 0x01, state byte]
    //         │
    //         ▼
    //   Comparator(eq 1)         — pass only press events (state == 1)
    //         │
    //         ▼
    //   Counter(outputSize: 1)   — increment-on-each-press counter (UInt8)
    //         │
    //         ▼
    //   Math(.modulo, rhs: 2)    — counter % 2 → 1 (odd) or 0 (even)
    //         │
    //         ├─► Comparator(eq 1)  ─► Event ─► executeMacro(blue-flash)
    //         │
    //         └─► Comparator(eq 0)  ─► Event ─► executeMacro(green-flash)
    //
    // Press 1 → counter=1 → mod2=1 → isOdd matches → BLUE.
    // Press 2 → counter=2 → mod2=0 → isEven matches → GREEN.
    // So odd presses (1st, 3rd, 5th, …) are BLUE; even presses are GREEN.
    //
    // Each LED action is itself a tiny 2-step macro (SetPattern + Play) since
    // an event's action is a single command and we need both writes to land
    // for a fresh pattern to play. Macro IDs returned by `recordMacro`
    // become the param byte of the event's `executeMacro` action.
    //
    // ### Why two filters instead of one event with a data token?
    //
    // A tempting simplification is to drop the isEven/isOdd comparators and
    // put a 1-byte `MWEventDataToken` on a single event so the firmware
    // splices mod2's output directly into the `executeMacro` macro_id at fire
    // time (and macro IDs are 0=green, 1=blue after `eraseAllMacros`). On the
    // wire that costs 2 fewer processors + 1 fewer event.
    //
    // It does not work on real firmware. Observed symptom: every press
    // flashes BOTH macros in sequence (green, then blue) instead of the one
    // selected by the spliced byte. Best guess is that the firmware fires
    // the static action first (params[0] = placeholder 0x00 → executeMacro 0
    // = green) AND a separate spliced action (executeMacro <mod2> = the
    // intended one). Without firmware source to confirm the splice
    // semantics for `executeMacro` destinations, the safe, slot-heavier
    // double-comparator approach is what we ship.

    @Test @MainActor
    func events_oddEvenPresses_alternateLEDColors() async throws {
        try await withConnectedDevice { device in
            // Start clean — leftover events / macros / processors from a
            // prior run would consume firmware slots this test needs.
            try await resetBoardState(device)

            // Two macros: each plays a different LED color when invoked.
            let greenMacro = try await device.recordMacro(commands: [
                MWLED.SetPattern(color: .green, .flash),
                MWLED.Play()
            ])
            let blueMacro = try await device.recordMacro(commands: [
                MWLED.SetPattern(color: .blue, .flash),
                MWLED.Play()
            ])

            // Build the processor chain on the switch state signal.
            let pressFilter = try await device.createProcessor(
                MWDataProcessor.Comparator(operation: .eq, reference: 1, signed: false),
                source: MWSwitchSignal()
            )
            let counter = try await device.createProcessor(
                MWDataProcessor.Counter(outputSize: 1),
                source: pressFilter
            )
            let mod2 = try await device.createProcessor(
                MWDataProcessor.Math(operation: .modulo, rhs: 2, signed: false, outputSize: 1),
                source: counter
            )
            let isOdd = try await device.createProcessor(
                MWDataProcessor.Comparator(operation: .eq, reference: 1, signed: false),
                source: mod2
            )
            let isEven = try await device.createProcessor(
                MWDataProcessor.Comparator(operation: .eq, reference: 0, signed: false),
                source: mod2
            )

            // `executeMacro(_)` on the wire is `[0x0F, 0x05, macro_id]` — wrap
            // each as an event action that fires the corresponding macro.
            let oddEvent = try await device.createEvent(
                source: MWEventSource(module: .dataProcessor, register: 0x03, dataID: isOdd.id),
                action: MWEventAction(module: .macro, register: 0x05, params: Data([blueMacro.id]))
            )
            let evenEvent = try await device.createEvent(
                source: MWEventSource(module: .dataProcessor, register: 0x03, dataID: isEven.id),
                action: MWEventAction(module: .macro, register: 0x05, params: Data([greenMacro.id]))
            )

            print("""

              Processor chain:
                pressFilter (Comparator eq 1)        → id \(pressFilter.id)
                counter     (Counter outputSize=1)   → id \(counter.id)
                mod2        (Math .modulo rhs=2)     → id \(mod2.id)
                isOdd       (Comparator eq 1)        → id \(isOdd.id)
                isEven      (Comparator eq 0)        → id \(isEven.id)
              Macros:
                blueMacro                             → id \(blueMacro.id)  (odd press)
                greenMacro                            → id \(greenMacro.id)  (even press)
              Events:
                oddEvent                              → id \(oddEvent.id)
                evenEvent                             → id \(evenEvent.id)

              ▶ Tap the board's button several times — LED should alternate
                BLUE on 1st, 3rd, 5th press  ↔  GREEN on 2nd, 4th, 6th press
              ▶ Waiting 12 s …

            """)
            try await Task.sleep(for: .seconds(12))

            // Cleanup — order matters: events reference processors; processors
            // reference each other; macros are referenced by event actions.
            try await device.removeAllEvents()
            try await device.removeAllProcessors()
            try await device.eraseAllMacros()
            try await device.send(MWLED.Stop(clearPattern: true))
        }
    }

    // MARK: - Macro-embedded event binding (port of legacy
    //         `test_MacroEventRecording_LEDFlashOnButtonUpDown`)
    //
    // The legacy test wrapped a `recordEvents(for: .buttonRelease, ...)` and a
    // `recordEvents(for: .buttonPress, ...)` inside a macro recorded with
    // `runOnStartup: true`. After the macro was committed, every subsequent
    // power-on of the board would re-establish the LED-flash-on-button binding
    // automatically, with no host involvement.
    //
    // The Swift 6 SDK now supports the same pattern via the closure form
    // `recordMacro(executeOnBoot:_:)` — the closure receives an `MWMacroRecorder`
    // whose `createEvent(...)` records the event ENTRY (and any CMD_PARAMETERS)
    // bytes into the macro buffer instead of round-tripping to the board for an
    // ID. When the macro replays, the firmware processes the embedded ENTRY as
    // if the host had just sent it, assigning a fresh event ID each time.
    //
    // We can't easily exercise the *reboot* half of the persistence story in an
    // automated suite (it requires power-cycling the board and re-discovering
    // it), so instead we:
    //   1. Record the macro with `executeOnBoot: true`.
    //   2. Manually trigger it once via `executeMacro(_:)` — this exercises the
    //      same replay code path the firmware would run on power-on, and
    //      establishes the live event binding for the test window.
    //   3. Operator taps the button; LED should flash green on each transition.
    //   4. Cleanup tears down both the live binding (`removeAllEvents`) and the
    //      persisted macro (`eraseAllMacros`).

    @Test @MainActor
    func macro_buttonChanged_flashesLED_persistsViaMacro() async throws {
        try await withConnectedDevice { device in
            // Start clean — a prior run could have left behind events, macros,
            // OR processors (this suite shares board state across tests). All
            // three must be wiped: leftover macros could replay on connect,
            // leftover events could double-fire the LED, leftover processors
            // would consume slots a future test in the suite needs.
            try await resetBoardState(device)

            // Record a macro that, on every replay, sets up a green flash
            // pattern and binds button-change → LED Play.
            let macro = try await device.recordMacro(executeOnBoot: true) { recorder in
                await recorder.send(MWLED.SetPattern(color: .green, .flash))
                await recorder.createEvent(
                    source: .buttonChanged(),
                    action: MWEventAction(command: MWLED.Play())
                )
            }

            // Replay it once to wire up the event binding for the test window.
            // This exercises the same code path the firmware would run on boot.
            try await device.executeMacro(macro)

            print("""

              Macro \(macro.id) recorded with executeOnBoot=true:
                packet 1: MWLED.SetPattern(color: .green, .flash)
                packet 2: createEvent(buttonChanged → MWLED.Play)
              ▶ Macro replayed once via executeMacro — event binding is now live
              ▶ Tap the board's button — LED should flash green on each press / release
              ▶ Waiting 6 s …

            """)
            try await Task.sleep(for: .seconds(6))

            // Cleanup — order matters: clear the live event binding first (so
            // the firmware doesn't keep firing it after we've torn down the
            // macro state), then erase the persisted macro so it won't replay
            // on the next boot.
            try await device.removeAllEvents()
            try await device.eraseAllMacros()
            try await device.send(MWLED.Stop(clearPattern: true))
        }
    }

    // MARK: - Throttled-fusion logging (port of legacy
    //         `test_EventTimeThrottling_SlowSensorFusion_Download_*`)
    //
    // The legacy tests took the fusion euler-angles output (16 bytes per sample
    // at ~100 Hz on hardware) and pushed it through a `Time(1 Hz, .passthrough)`
    // processor before logging the throttled output. After 10 s of operation
    // the on-device flash should hold ~10 entries — with some slack for
    // start/stop boundary races, hence the legacy `accuracy: 2`.
    //
    // The flow on the new SDK:
    //   1. `prepareSignalSource(MWSensorFusionEuler)` — runs configure / enable /
    //      start so the underlying acc, gyro, (mag) and the fusion engine all
    //      produce data on-board. We don't subscribe — the host doesn't need
    //      the raw samples.
    //   2. `createProcessor(MWDataProcessor.Time(1 Hz), source: MWSensorFusionEulerSignal())`
    //      — the firmware allocates a new processor; the handle's output is the
    //      same shape as its input (16 bytes, 4 × float32 channels) at 1 Hz.
    //   3. `startLogging(handle, key: "euler-1hz")` — splits the 16-byte output
    //      into 4 × 4-byte chunks and registers a logger ID per chunk.
    //   4. Wait 10 s.
    //   5. `stopLogging(key:) → teardownSignalSource → flushLogPage` — stop the
    //      firmware writing to flash, then push the last page out so the
    //      download sees every entry.
    //   6. `downloadLogs(key:decode:)` with a closure that prepends the
    //      [module, register] header so the standard `parseEulerAngles` works.
    //   7. Cleanup: `removeAllProcessors` + `clearLog` so subsequent test runs
    //      start from a clean board state.

    @Test @MainActor
    func throttledFusion_logsAtOneHz_downloads() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            // Start clean — leftover loggers / processors / events / macros
            // from any prior test would conflict. A boot-time macro from an
            // earlier `macro_buttonChanged_flashesLED_persistsViaMacro` run
            // could even re-fire button events during this test's window.
            try await resetBoardState(device)

            // Pick the richest fusion mode the board supports (NDOF if a mag
            // is present; otherwise IMU+).
            let mode = await device.hasMagnetometer ? MWSensorFusionMode.ndof : .imuPlus
            let chip: MWSensorFusionChip
            if let impl = await device.moduleInfo(for: .gyro)?.implementation,
               let detected = MWSensorFusionChip(gyroImpl: impl) {
                chip = detected
            } else {
                chip = .bmi160
            }
            let euler = MWSensorFusionEuler(mode: mode, chip: chip)

            // 1. Bring the fusion data path up without subscribing.
            try await device.prepareSignalSource(euler)

            // 2. Create the throttle processor on the euler signal.
            let throttle = try await device.createProcessor(
                MWDataProcessor.Time(periodMs: 1000, mode: .absolute),
                source: MWSensorFusionEulerSignal()
            )

            // 3. Log the processor's 1 Hz output.
            let key = "euler-throttle-1hz"
            try await device.startLogging(throttle, key: key)

            print("""

              Fusion source: \(mode) on \(chip)
              Processor:     Time(1 Hz, .absolute) → handle id \(throttle.id)
              Logger key:    "\(key)"
              ▶ Waiting 10 s — should land ~10 entries on flash …

            """)
            try await Task.sleep(for: .seconds(10))

            // 4. Tear down the source and flush the last log page.
            try await device.stopLogging(key: key)
            try await device.teardownSignalSource(euler)
            _ = try await device.flushLogPage()
            try await Task.sleep(for: .milliseconds(500))

            // 5. Download — decoder reassembles the 16 bytes into EulerAngles.
            //    `MWSensorFusionEuler.parseLogSample(from:)` is the public
            //    decoder for the same byte layout as the raw fusion signal —
            //    it prepends the [module, register] header internally.
            let stream = try await device.downloadLogs(key: key) { data in
                try euler.parseLogSample(from: data)
            }
            var samples: [MWLoggedSample<EulerAngles>] = []
            for try await progress in stream {
                samples = progress.data
            }

            print("\n  Downloaded \(samples.count) throttled euler samples (expected ~10 ± 2)\n")

            // Legacy: `XCTAssertEqual(rowCount, 10, accuracy: 2)` — same window.
            #expect(samples.count >= 8 && samples.count <= 12,
                    "Expected ~10 ± 2 samples after 10 s @ 1 Hz, got \(samples.count)")

            // Spot-check that we got real EulerAngles, not zeroed-out structs.
            // After fusion has had a few hundred ms to settle, every sample
            // should have at least one non-zero axis.
            if let last = samples.last {
                let v = last.value
                let anyNonZero = v.heading != 0 || v.pitch != 0 || v.roll != 0 || v.yaw != 0
                #expect(anyNonZero, "Last sample looks all-zero: \(v)")
            }

            // 6. Cleanup — remove the processor, wipe the log, leave the
            //    board ready for the next test.
            try await device.removeAllProcessors()
            try await device.clearLog()
        }
    }
}
