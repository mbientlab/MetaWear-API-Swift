//
//  SwitchTests.swift
//  MetaWear
//
//  Hardware-required tests for the push-button switch (module 0x01, register 0x01).
//

import Testing
import MetaWear
import Foundation

@Suite("Hardware — Switch", .serialized)
struct SwitchTests {

    // MARK: - Stream lifecycle
    //
    // The switch signal does not require any configure/enable commands — a
    // bare subscribe + unsubscribe is enough. This test verifies startStream /
    // stopStreaming complete without error and prints every button transition
    // that arrives during the listen window so the operator can confirm live
    // hardware feedback.

    @Test @MainActor
    func switch_streamStarts_withoutError() async throws {
        try await withConnectedDevice { device in
            let stream = try await device.startStream(MWSwitch())

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"

            print("\n  ▸ Switch stream started — press the button to see live state\n")

            let collector = Task {
                var transitions = 0
                for try await event in stream {
                    let stamp = formatter.string(from: event.time)
                    let state = event.value ? "PRESSED " : "released"
                    print("    [\(stamp)] button \(state)")
                    transitions += 1
                }
                print("    (\(transitions) transition\(transitions == 1 ? "" : "s") observed)")
            }

            // Keep the stream open long enough for the operator to press / release.
            try await Task.sleep(for: .seconds(10))
            collector.cancel()
            try await device.stopStreaming(MWSwitch())

            print("\n  ▸ Switch stream stopped without error\n")
        }
    }
}
