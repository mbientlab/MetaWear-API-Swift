import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import MetaWear

// MARK: - Notification routing

@Suite("Protocol Layer — Notification Routing")
struct ProtocolLayerRoutingTests {

    // Build a mock + protocol layer, start the router, return both
    private func makePair() async -> (MockBLETransport, MWProtocolLayer) {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()
        return (transport, proto)
    }

    @Test func readResponse_resumesContinuation() async throws {
        let (transport, proto) = await makePair()

        // Fire off a read (parks a CheckedContinuation internally)
        async let response = proto.read(.accelerometer, 0x03)

        // Give the routing task a moment to register the waiter
        try await Task.sleep(nanoseconds: 5_000_000)  // 5ms

        // Inject the response: module=0x03, register=0x83 (0x03 | 0x80)
        let reply = Data([0x03, 0x83, 0xAA, 0xBB])
        await transport.inject(notification: reply, to: MWUUIDs.notify)

        let data = try await response
        #expect(data == reply)
    }

    @Test func notificationRoutes_toSubscriber() async throws {
        let (transport, proto) = await makePair()

        let stream = await proto.subscribe(to: .accelerometer, register: 0x04)

        // Give subscribe a moment to register
        try await Task.sleep(nanoseconds: 5_000_000)

        let packet = Data([0x03, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00, 0x20])
        await transport.inject(notification: packet, to: MWUUIDs.notify)

        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == packet)
    }

    @Test func unsubscribe_finishesStream() async throws {
        let (_, proto) = await makePair()

        let stream = await proto.subscribe(to: .gyro, register: 0x05)
        await proto.unsubscribe(from: .gyro, register: 0x05)

        // Stream should terminate cleanly (next returns nil)
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        #expect(value == nil)
    }

    @Test func stop_terminatesAllWaiters() async throws {
        let (_, proto) = await makePair()

        // Park a read waiter
        async let pendingRead: Data = proto.read(.accelerometer, 0x03)

        try await Task.sleep(nanoseconds: 5_000_000)
        await proto.stop()

        do {
            _ = try await pendingRead
            Issue.record("Expected an error but read succeeded")
        } catch {
            // Expected: proto.stop() should throw to all parked waiters
        }
    }

    @Test func stop_finishesAllSubscriberStreams() async throws {
        let (_, proto) = await makePair()

        let stream = await proto.subscribe(to: .barometer, register: 0x01)

        try await Task.sleep(nanoseconds: 5_000_000)
        await proto.stop()

        // The stream should end with an error
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream to terminate with error")
        } catch {
            // Expected
        }
    }

    @Test func multipleReadWaiters_sameKey_bothResolve() async throws {
        let (transport, proto) = await makePair()

        // Two concurrent reads on the same (module, register)
        async let first: Data  = proto.read(.accelerometer, 0x00)
        async let second: Data = proto.read(.accelerometer, 0x00)

        // `sendAndAwait` enqueues each waiter *before* writing the read command
        // to the transport — so once we observe both writes on the transport,
        // both continuations are guaranteed parked. A fixed sleep races against
        // task scheduling under parallel-test load and was the source of an
        // intermittent timeout here.
        for _ in 0..<200 {
            if await transport.writtenData.count >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)   // 1 ms × 200 = 200 ms cap
        }

        let reply1 = Data([0x03, 0x80, 0x01])
        let reply2 = Data([0x03, 0x80, 0x02])
        await transport.inject(notification: reply1, to: MWUUIDs.notify)
        await transport.inject(notification: reply2, to: MWUUIDs.notify)

        let r1 = try await first
        let r2 = try await second

        // Both waiters must get resolved with one of the two replies (FIFO, but
        // scheduler ordering between the two async let tasks is not guaranteed,
        // so we only assert that they together received the full set of replies).
        let received = Set([r1, r2])
        #expect(received == Set([reply1, reply2]))
    }

    @Test func readBitStripped_forRouting() async throws {
        let (transport, proto) = await makePair()

        // Read register 0x04; response comes back with bit 7 set (0x84)
        async let response = proto.read(.accelerometer, 0x04)

        try await Task.sleep(nanoseconds: 5_000_000)

        // Firmware echoes back with the read bit set
        await transport.inject(notification: Data([0x03, 0x84, 0xFF]), to: MWUUIDs.notify)

        let data = try await response
        #expect(data[1] == 0x84)   // full packet preserved; routing stripped bit internally
    }
}

// MARK: - Module discovery

@Suite("Protocol Layer — Module Discovery")
struct ProtocolLayerDiscoveryTests {

    @Test func discoverModules_parsesAllResponses() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        // Discovery fires a read [module, 0x80] for each MWModule.
        // Continuously poll for those reads and inject a reply the first time
        // we see each one — a one-shot sleep races against parallel-test load.
        let replyTask = Task {
            var responded = Set<Data>()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000)
                let written = await transport.writtenData
                for (cmd, _, _) in written {
                    guard cmd.count >= 2 else { continue }
                    let regByte = cmd[1]
                    guard (regByte & 0x80) != 0 else { continue }   // only reads
                    guard !responded.contains(cmd) else { continue }
                    responded.insert(cmd)
                    // Reply: [module, 0x80, impl=0x01, rev=0x00]
                    let reply = Data([cmd[0], 0x80, 0x01, 0x00])
                    await transport.inject(notification: reply, to: MWUUIDs.notify)
                }
            }
        }

        let modules = try await proto.discoverModules()
        replyTask.cancel()

        // All modules that were replied to should be present
        #expect(!modules.isEmpty)
        // Specifically the accelerometer (0x03) should be present
        if let info = modules[.accelerometer] {
            #expect(info.implementation == 0x01)
            #expect(info.revision == 0x00)
        }
    }

    @Test func moduleInfo_impl0xFF_marksAbsent() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        // Discover only accelerometer — all others are given impl=0xFF (absent)
        let replyTask = Task {
            var responded = Set<Data>()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000)
                let written = await transport.writtenData
                for (cmd, _, _) in written {
                    guard cmd.count >= 2, (cmd[1] & 0x80) != 0 else { continue }
                    guard !responded.contains(cmd) else { continue }
                    responded.insert(cmd)
                    let moduleId = cmd[0]
                    let impl: UInt8 = moduleId == 0x03 ? 0x01 : 0xFF
                    let reply = Data([moduleId, 0x80, impl, 0x00])
                    await transport.inject(notification: reply, to: MWUUIDs.notify)
                }
            }
        }

        let modules = try await proto.discoverModules()
        replyTask.cancel()

        if let gyroInfo = modules[.gyro] {
            #expect(!gyroInfo.isPresent)
        }
        if let accInfo = modules[.accelerometer] {
            #expect(accInfo.isPresent)
        }
    }
}

// MARK: - Write passthrough

@Suite("Protocol Layer — Write Passthrough")
struct ProtocolLayerWriteTests {

    @Test func write_forwardsToTransport() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        let cmd = Data([0x03, 0x01, 0x01])
        try await proto.write(cmd)

        let written = await transport.writtenData
        #expect(written.count == 1)
        #expect(written[0].0 == cmd)
        #expect(written[0].1 == MWUUIDs.command)
        #expect(written[0].2 == .withoutResponse)
    }

    @Test func writeMacro_usesWithResponse() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        await proto.start()

        try await proto.writeMacro(Data([0x0F, 0x02]))

        let written = await transport.writtenData
        #expect(written.last?.2 == .withResponse)
    }
}
