import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import MetaWear

// MARK: - Helpers
//
// Re-declared per file because Swift Testing runs the whole target but
// `private` helpers don't cross file boundaries.

private func makeConnectableTransport() async -> MockBLETransport {
    let t = MockBLETransport()
    await t.setReadResponse(Data("MbientLab".utf8),   for: MWUUIDs.manufacturerName)
    await t.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await t.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await t.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await t.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)
    return t
}

/// Continuously poll for module-discovery reads (`[module, 0x80]`) and the
/// log-time-reference read (`[0x0B, 0x84]`) and inject canned replies so
/// `connect()` can complete. Mirrors the pattern in MWLogFinishingTests.swift.
private func autoReplyDiscovery(transport: MockBLETransport) -> Task<Void, Never> {
    Task {
        var responded = Set<Data>()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let cmds = await transport.writtenCommands
            for cmd in cmds {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !responded.contains(cmd) else { continue }
                responded.insert(cmd)

                // Logging time read: [0x0B, 0x84]
                if cmd[0] == 0x0B && cmd[1] == 0x84 {
                    await transport.inject(
                        notification: Data([0x0B, 0x84, 0, 0, 0, 0, 0]),
                        to: MWUUIDs.notify
                    )
                    continue
                }
                let impl: UInt8 = ([0x03, 0x0B, 0x13, 0x12, 0x15, 0x19].contains(cmd[0])) ? 0x01 : 0xFF
                await transport.inject(
                    notification: Data([cmd[0], 0x80, impl, 0x00]),
                    to: MWUUIDs.notify
                )
            }
        }
    }
}

private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = await makeConnectableTransport()
    let device = MetaWearDevice(identifier: UUID(), transport: transport)
    let discovery = autoReplyDiscovery(transport: transport)
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

/// Filter to only those writes that hit the command characteristic (drops
/// macro-with-response writes and notifications, although neither apply
/// to `factoryReset()` — kept for symmetry with the other suites).
private func commandWrites(after baseline: Int, _ transport: MockBLETransport) async -> [Data] {
    let written = await transport.writtenData
    let cmds = written.compactMap { data, uuid, _ in
        uuid == MWUUIDs.command ? data : nil
    }
    return Array(cmds.dropFirst(baseline))
}

// MARK: - Suite

@Suite("MetaWearDevice — factoryReset")
struct MWFactoryResetTests {

    /// Mirrors the Python C-API call sequence, with one addition (step 8):
    ///   mbl_mw_logging_stop
    ///   mbl_mw_logging_clear_entries
    ///   mbl_mw_event_remove_all
    ///   mbl_mw_dataprocessor_remove_all
    ///   mbl_mw_macro_erase_all
    ///   mbl_mw_debug_reset_after_gc
    ///   mbl_mw_debug_reset                  // immediate-reset fallback
    ///
    /// The trailing `[0xFE, 0x01]` is needed because some firmware revisions
    /// (observed: MMS fw 1.5.0) silently ignore `[0xFE, 0x05]` when the flash
    /// GC queue is empty, leaving the boot counter unchanged. See the
    /// `factoryReset` doc comment in `MetaWearDevice`.
    @Test func factoryReset_emitsExpectedByteSequenceInOrder() async throws {
        let (device, transport) = try await connectedDevice()
        let baseline = await transport.writtenData.compactMap {
            $0.1 == MWUUIDs.command ? $0.0 : nil
        }.count

        try await device.factoryReset()

        let new = await commandWrites(after: baseline, transport)
        #expect(new == [
            Data([0x0B, 0x01, 0x00]),                        // 1. stop logging
            Data([0x0B, 0x09, 0xFF, 0xFF, 0xFF, 0xFF]),      // 2. drop log entries
            Data([0x0B, 0x0A]),                              // 3. remove all loggers
            Data([0x0A, 0x05]),                              // 4. remove all events
            Data([0x09, 0x08]),                              // 5. remove all processors
            Data([0x0F, 0x08]),                              // 6. erase all macros
            Data([0xFE, 0x05]),                              // 7. reset after GC
            Data([0xFE, 0x01]),                              // 8. immediate-reset fallback
        ])
    }

    @Test func factoryReset_transitionsToDisconnected() async throws {
        let (device, _) = try await connectedDevice()
        let pre = await device.state
        #expect(pre == .idle)

        try await device.factoryReset()
        let post = await device.state
        #expect(post == .disconnected)
    }

    @Test func factoryReset_clearsLoggerRegistry() async throws {
        let (device, transport) = try await connectedDevice()

        // Seed the registry by starting (and not stopping) a logger session.
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        let injector = Task {
            // BMI160 emits two log-data chunks, so two logger-id responses.
            for id in [UInt8(0x00), UInt8(0x01)] {
                try? await Task.sleep(nanoseconds: 10_000_000)
                await transport.inject(notification: Data([0x0B, 0x02, id]), to: MWUUIDs.notify)
            }
        }
        defer { injector.cancel() }
        try await device.startLogging(sensor)
        #expect(await device._loggerRegistryHasKey(sensor.loggerKey) == true)

        try await device.factoryReset()
        #expect(await device._loggerRegistryHasKey(sensor.loggerKey) == false)
    }

    @Test func factoryReset_clearsLogReferenceDate() async throws {
        let (device, _) = try await connectedDevice()
        // connect() reads the time anchor; reference date should now be set.
        #expect(await device._logReferenceDate() != nil)

        try await device.factoryReset()
        #expect(await device._logReferenceDate() == nil)
    }

    @Test func factoryReset_whenAlreadyDisconnected_throws() async throws {
        let device = MetaWearDevice(identifier: UUID(), transport: MockBLETransport())
        do {
            try await device.factoryReset()
            Issue.record("Expected invalidState when factoryReset called on a disconnected device")
        } catch let err as MWError {
            if case .invalidState = err { /* expected */ }
            else { Issue.record("Wrong error: \(err)") }
        }
    }

    @Test func factoryReset_fromLoggingState_succeeds() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
        let injector = Task {
            for id in [UInt8(0x00), UInt8(0x01)] {
                try? await Task.sleep(nanoseconds: 10_000_000)
                await transport.inject(notification: Data([0x0B, 0x02, id]), to: MWUUIDs.notify)
            }
        }
        defer { injector.cancel() }
        try await device.startLogging(sensor)
        #expect(await device.state == .logging)

        // factoryReset is intentionally permissive about the starting state —
        // the reboot wipes everything regardless.
        try await device.factoryReset()
        #expect(await device.state == .disconnected)
    }
}
