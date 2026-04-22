import Testing
import MetaWear

@Suite("Hardware — Macro", .serialized)
struct MacroTests {

    @Test @MainActor
    func macro_recordAndExecute() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.SetPattern(color: .green, .blink))
            let macro = try await device.recordMacro(
                executeOnBoot: false,
                commands: [MWLED.Play()]
            )

            try await device.executeMacro(macro)
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop(clearPattern: true))
            try await device.eraseAllMacros()

            print("\n  ✓ Macro \(macro.id) executed — LED should have blinked green\n")
        }
    }

    @Test @MainActor
    func macro_multipleCommands() async throws {
        try await withConnectedDevice { device in
            let macro = try await device.recordMacro(
                executeOnBoot: false,
                commands: [
                    MWLED.SetPattern(color: .blue, .flash),
                    MWLED.Play()
                ]
            )
            try await device.executeMacro(macro)
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop(clearPattern: true))
            try await device.eraseAllMacros()
            print("\n  ✓ Multi-command macro (SetPattern + Play) executed\n")
        }
    }

    @Test @MainActor
    func macro_eraseAll_succeeds() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.SetPattern(color: .red, .flash))
            _ = try await device.recordMacro(executeOnBoot: false, commands: [MWLED.Play()])
            try await device.eraseAllMacros()
        }
    }
}
