import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import MetaWear

// MARK: - Mock-transport convenience shared with MetaWearDeviceTests
//
// These helpers mirror the ones in MetaWearDeviceTests.swift but are
// re-declared here so this file is self-contained (Swift Testing runs the
// whole target but fileprivate helpers don't cross file boundaries).

private func makeConnectableTransport() async -> MockBLETransport {
    let t = MockBLETransport()
    await t.setReadResponse(Data("MbientLab".utf8),  for: MWUUIDs.manufacturerName)
    await t.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await t.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await t.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await t.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)
    return t
}

private func autoReplyModuleDiscovery(transport: MockBLETransport) -> Task<Void, Never> {
    // Continuously poll — see MetaWearDeviceTests for the rationale on why a
    // one-shot sleep is racy under parallel-test load.
    Task {
        var responded = Set<Data>()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let written = await transport.writtenData
            for (cmd, _, _) in written {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                guard !responded.contains(cmd) else { continue }
                responded.insert(cmd)
                let moduleId = cmd[0]
                let present: Set<UInt8> = [0x03, 0x13, 0x12, 0x15, 0x19, 0x0B, 0x11, 0x16]
                let impl: UInt8 = present.contains(moduleId) ? 0x01 : 0xFF
                await transport.inject(notification: Data([moduleId, 0x80, impl, 0x00]),
                                       to: MWUUIDs.notify)
            }
        }
    }
}

private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = await makeConnectableTransport()
    let device = MetaWearDevice(identifier: UUID(), transport: transport)
    let discovery = autoReplyModuleDiscovery(transport: transport)
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

// MARK: - Generic device.read(_:)

@Suite("MetaWearDevice — Generic read(_:)")
struct GenericReadTests {

    @Test func read_humidity_yieldsTimestampedFloat() async throws {
        let (device, transport) = try await connectedDevice()

        let inject = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            // BME280 vector: raw 64711 / 1024 = 63.1943°%
            await transport.inject(
                notification: Data([0x16, 0x81, 0xC7, 0xFC, 0x00, 0x00]),
                to: MWUUIDs.notify
            )
        }
        defer { inject.cancel() }

        let before = Date()
        let sample = try await device.read(MWHumidity())
        let after = Date()
        #expect(sample.value == 63.1943359375)
        #expect(sample.time >= before)
        #expect(sample.time <= after)
    }

    @Test func read_logLength_yieldsEntryCount() async throws {
        let (device, transport) = try await connectedDevice()

        let inject = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            // 0x0000_04D2 = 1234 entries
            await transport.inject(
                notification: Data([0x0B, 0x85, 0xD2, 0x04, 0x00, 0x00]),
                to: MWUUIDs.notify
            )
        }
        defer { inject.cancel() }

        let sample = try await device.read(MWLogLength())
        #expect(sample.value == 1234)
    }

    @Test func read_macAddress_yieldsColonString() async throws {
        let (device, transport) = try await connectedDevice()

        let inject = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await transport.inject(
                notification: Data([0x11, 0x8B, 0x01, 0x07, 0x7B, 0x52, 0x8F, 0xC9, 0xE8]),
                to: MWUUIDs.notify
            )
        }
        defer { inject.cancel() }

        let sample = try await device.read(MWMACAddress())
        #expect(sample.value == "E8:C9:8F:52:7B:07")
    }
}

// MARK: - device.poll(_:every:)

@Suite("MetaWearDevice — poll(_:every:)")
struct DevicePollTests {

    @Test func poll_deliversMultipleSamples() async throws {
        let (device, transport) = try await connectedDevice()

        // Drip-feed three humidity responses in the background. Each read
        // emits a packet write; we watch for those and inject a reply.
        let feeder = Task {
            var served = 0
            while served < 3, !Task.isCancelled {
                let written = await transport.writtenData
                let reads = written.filter {
                    $0.0.count >= 2 && $0.0[0] == 0x16 && $0.0[1] == 0x81
                }
                if reads.count > served {
                    await transport.inject(
                        notification: Data([0x16, 0x81, 0x00, 0xC0, 0x00, 0x00]),  // 48%
                        to: MWUUIDs.notify
                    )
                    served += 1
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { feeder.cancel() }

        let stream = await device.poll(MWHumidity(), every: .milliseconds(10))
        var samples: [Timestamped<Float>] = []
        for try await s in stream {
            samples.append(s)
            if samples.count == 3 { break }
        }
        #expect(samples.count == 3)
        #expect(samples.allSatisfy { $0.value == 48.0 })
        // Times should be non-decreasing.
        for (a, b) in zip(samples, samples.dropFirst()) {
            #expect(a.time <= b.time)
        }
    }

    @Test func poll_cancellation_stopsStream() async throws {
        let (device, transport) = try await connectedDevice()

        // Serve responses as they come in, indefinitely.
        let feeder = Task {
            var served = 0
            while !Task.isCancelled {
                let written = await transport.writtenData
                let reads = written.filter {
                    $0.0.count >= 2 && $0.0[0] == 0x16 && $0.0[1] == 0x81
                }
                if reads.count > served {
                    await transport.inject(
                        notification: Data([0x16, 0x81, 0x00, 0xC0, 0x00, 0x00]),
                        to: MWUUIDs.notify
                    )
                    served += 1
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { feeder.cancel() }

        let stream = await device.poll(MWHumidity(), every: .milliseconds(10))

        // Consume one sample, then abandon the iterator — the stream's
        // onTermination should cancel the polling Task.
        var iter = stream.makeAsyncIterator()
        let first = try await iter.next()
        #expect(first != nil)
        // Dropping `iter` terminates the stream; give the cancellation a
        // moment to propagate and confirm no crash / deadlock.
        _ = iter
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
