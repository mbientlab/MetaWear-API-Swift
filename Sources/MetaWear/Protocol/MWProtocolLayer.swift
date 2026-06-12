import Foundation

// MARK: - Routing key

struct ModuleRegisterKey: Hashable, Sendable {
    let module: UInt8
    let register: UInt8  // always normalized — bit 7 stripped
}

// MARK: - Read waiter

/// Pairs a read continuation with a unique ID so timeouts can cancel
/// a specific waiter without disturbing others queued on the same key.
private struct ReadWaiter: Sendable {
    let id: UUID
    let continuation: CheckedContinuation<Data, Error>
}

// MARK: - Protocol layer

/// Routes all BLE notifications to the correct handlers.
/// Sits between the BLETransport and the sensor modules.
actor MWProtocolLayer {

    // MARK: - Configuration

    /// Maximum time to wait for a read response before throwing `MWError.timeout`.
    static let readTimeout: Duration = .seconds(5)

    // MARK: - State

    private let transport: any BLETransport

    // One-shot read waiters — keyed by (module, register), ordered FIFO.
    // Used when the board echoes back a response with bit 7 set on the register byte.
    private var readWaiters: [ModuleRegisterKey: [ReadWaiter]] = [:]

    // One-shot notification waiters — keyed by (module, register), ordered FIFO.
    // Used when the board responds with a plain notification (bit 7 NOT set), e.g. I2C/SPI reads.
    private var notifyWaiters: [ModuleRegisterKey: [ReadWaiter]] = [:]

    /// Waiter IDs whose cancellation arrived before the waiter was enqueued.
    ///
    /// `sendAndAwait`/`writeAndAwaitNotification` park their continuation from
    /// an unstructured `Task`, while the task-group's `onCancel` handler runs
    /// `cancelRead`/`cancelNotifyWaiter` from another. If the cancel lands
    /// first, it finds no waiter to fail — and the enqueue that follows would
    /// park a continuation nothing ever resumes, deadlocking the call at the
    /// task-group scope exit. Tombstoning the ID makes the enqueue fail the
    /// continuation immediately regardless of ordering. Cleared wholesale in
    /// `failAllWaiters` so rare orphans (cancel racing a normal resume) can't
    /// accumulate across connections.
    private var tombstonedWaiterIDs: Set<UUID> = []

    // Ongoing notification subscribers — keyed by (module, register).
    private var notifyStreams: [ModuleRegisterKey: NotifyStream] = [:]

    /// Pairs a stream continuation with a generation counter so the
    /// `onTermination` cleanup can tell whether the dictionary entry it is
    /// about to remove is still its own (a re-subscribe may have replaced it).
    private struct NotifyStream {
        let generation: UInt64
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
    }
    private var streamGeneration: UInt64 = 0

    private var routerTask: Task<Void, Never>?

    /// Called when the BLE connection drops unexpectedly (not via `stop()`).
    var onUnexpectedDisconnect: (@Sendable (Error) -> Void)?

    init(transport: any BLETransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    func start() {
        mwLog("[Proto] start")
        routerTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.notifications(from: MWUUIDs.notify)
            do {
                for try await packet in stream {
                    await self.route(packet: packet)
                }
                // Stream ended cleanly — transport disconnected without error
                await self.terminate(with: MWError.operationFailed("BLE connection closed"))
            } catch {
                await self.terminate(with: error)
            }
        }
    }

    func stop() {
        mwLog("[Proto] stop")
        routerTask?.cancel()
        routerTask = nil
        onUnexpectedDisconnect = nil
        let err = MWError.operationFailed("Protocol layer stopped")
        failAllWaiters(with: err)
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        onUnexpectedDisconnect = handler
    }

    func clearDisconnectHandler() {
        onUnexpectedDisconnect = nil
    }

    // MARK: - Sending

    /// Send a write-without-response command.
    func write(_ data: Data) async throws {
        mwLog("[Proto] write: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        try await transport.write(data, to: MWUUIDs.command, type: .withoutResponse)
    }

    /// Send a macro command (write-with-response).
    func writeMacro(_ data: Data) async throws {
        mwLog("[Proto] writeMacro: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        try await transport.write(data, to: MWUUIDs.command, type: .withResponse)
    }

    // MARK: - Reading

    /// Send a read command and await the matching response notification.
    /// Throws `MWError.timeout` if no response arrives within `readTimeout`.
    func read(_ module: MWModule, _ register: UInt8, _ payload: UInt8...) async throws -> Data {
        mwLog("[Proto] read: mod=\(String(format: "%02X", module.rawValue)) reg=\(String(format: "%02X", register))")
        let command = MWPacket.read(module, register, payload)
        return try await sendAndAwait(command: command, awaitModule: module, awaitRegister: register)
    }

    /// Write an arbitrary command and await a response notification on `(awaitModule, awaitRegister)`.
    /// Used for commands that trigger a board response on a different (or same) register.
    /// Throws `MWError.timeout` if no response arrives within `timeout` (default `readTimeout`).
    /// Pass a shorter `timeout` for probe-style reads where a missing response is an
    /// expected outcome (e.g. enumerating logger/processor slots), so the caller
    /// isn't stalled the full 5 s discovering "no more entries".
    func writeAndRead(command: Data, awaitModule: MWModule, awaitRegister: UInt8,
                      timeout: Duration = MWProtocolLayer.readTimeout) async throws -> Data {
        mwLog("[Proto] writeAndRead: \(command.map { String(format: "%02X", $0) }.joined(separator: " ")) awaitMod=\(String(format: "%02X", awaitModule.rawValue)) awaitReg=\(String(format: "%02X", awaitRegister))")
        return try await sendAndAwait(command: command, awaitModule: awaitModule, awaitRegister: awaitRegister, timeout: timeout)
    }

    /// Write a command and await a **plain notification** (bit 7 NOT set) on `(awaitModule, awaitRegister)`.
    /// Used for I2C and SPI reads where the board responds with an unsolicited data packet
    /// rather than a read-response (bit-7) packet.
    /// Throws `MWError.timeout` if no response arrives within `readTimeout`.
    func writeAndAwaitNotification(command: Data, awaitModule: MWModule, awaitRegister: UInt8) async throws -> Data {
        mwLog("[Proto] writeAndAwaitNotification: awaitMod=\(String(format: "%02X", awaitModule.rawValue)) awaitReg=\(String(format: "%02X", awaitRegister))")
        let key = ModuleRegisterKey(module: awaitModule.rawValue, register: awaitRegister & 0x3F)
        let waiterID = UUID()

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        Task {
                            await self.enqueueNotifyWaiter(key: key, id: waiterID, continuation: continuation)
                            do {
                                try await self.write(command)
                            } catch {
                                await self.cancelNotifyWaiter(key: key, id: waiterID, error: error)
                            }
                        }
                    }
                } onCancel: {
                    Task { await self.cancelNotifyWaiter(key: key, id: waiterID, error: MWError.timeout) }
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.readTimeout)
                throw MWError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func enqueueNotifyWaiter(key: ModuleRegisterKey, id: UUID, continuation: CheckedContinuation<Data, Error>) {
        if tombstonedWaiterIDs.remove(id) != nil {
            // Cancelled before we got here — fail immediately, never park.
            continuation.resume(throwing: MWError.timeout)
            return
        }
        notifyWaiters[key, default: []].append(ReadWaiter(id: id, continuation: continuation))
    }

    private func cancelNotifyWaiter(key: ModuleRegisterKey, id: UUID, error: Error) {
        guard var waiters = notifyWaiters[key],
              let idx = waiters.firstIndex(where: { $0.id == id }) else {
            // Not enqueued yet (or already resumed) — tombstone so a late
            // enqueue fails its continuation instead of parking it forever.
            tombstonedWaiterIDs.insert(id)
            return
        }
        let waiter = waiters.remove(at: idx)
        notifyWaiters[key] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: error)
    }

    private func sendAndAwait(command: Data, awaitModule: MWModule, awaitRegister: UInt8,
                              timeout: Duration = MWProtocolLayer.readTimeout) async throws -> Data {
        let key = ModuleRegisterKey(module: awaitModule.rawValue, register: awaitRegister & 0x3F)
        let waiterID = UUID()

        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Task 1: park a continuation and send the command
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        Task {
                            await self.enqueueRead(key: key, id: waiterID, continuation: continuation)
                            do {
                                try await self.write(command)
                            } catch {
                                await self.cancelRead(key: key, id: waiterID, error: error)
                            }
                        }
                    }
                } onCancel: {
                    // Called when the task group cancels this task (timeout won the race)
                    Task { await self.cancelRead(key: key, id: waiterID, error: MWError.timeout) }
                }
            }

            // Task 2: timeout sentinel
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MWError.timeout
            }

            // First result wins; cancel the loser
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func enqueueRead(key: ModuleRegisterKey, id: UUID, continuation: CheckedContinuation<Data, Error>) {
        if tombstonedWaiterIDs.remove(id) != nil {
            // Cancelled before we got here — fail immediately, never park.
            continuation.resume(throwing: MWError.timeout)
            return
        }
        readWaiters[key, default: []].append(ReadWaiter(id: id, continuation: continuation))
    }

    private func cancelRead(key: ModuleRegisterKey, id: UUID, error: Error) {
        guard var waiters = readWaiters[key],
              let idx = waiters.firstIndex(where: { $0.id == id }) else {
            // Not enqueued yet (or already resumed) — tombstone so a late
            // enqueue fails its continuation instead of parking it forever.
            tombstonedWaiterIDs.insert(id)
            return
        }
        let waiter = waiters.remove(at: idx)
        readWaiters[key] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: error)
    }

    // MARK: - Subscribing

    /// Subscribe to ongoing notifications from a module/register.
    ///
    /// Re-subscribing to the same key finishes the previous stream (its
    /// consumer sees a clean end rather than suspending forever). When the
    /// consumer stops iterating — cancellation or normal exit — the
    /// `onTermination` hook removes the registration, so abandoned streams
    /// don't linger in the routing table.
    func subscribe(to module: MWModule, register: UInt8) -> AsyncThrowingStream<Data, Error> {
        let key = ModuleRegisterKey(module: module.rawValue, register: register & 0x3F)
        notifyStreams[key]?.continuation.finish()
        streamGeneration += 1
        let generation = streamGeneration
        // Bounded buffer: sensor notifications arrive at up to ~200 packets/s.
        // If the consumer stalls, keep the newest packets rather than growing
        // the buffer without bound; for live sensor data, stale samples are
        // the right thing to shed.
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(key: key, generation: generation) }
        }
        notifyStreams[key] = NotifyStream(generation: generation, continuation: continuation)
        return stream
    }

    func unsubscribe(from module: MWModule, register: UInt8) {
        let key = ModuleRegisterKey(module: module.rawValue, register: register & 0x3F)
        notifyStreams[key]?.continuation.finish()
        notifyStreams.removeValue(forKey: key)
    }

    /// `onTermination` cleanup — only removes the entry if it still belongs to
    /// the terminating stream (a newer subscribe may have replaced it).
    private func removeStream(key: ModuleRegisterKey, generation: UInt64) {
        guard notifyStreams[key]?.generation == generation else { return }
        notifyStreams.removeValue(forKey: key)
    }

    // MARK: - Module discovery

    func discoverModules() async throws -> [MWModule: MWModuleInfo] {
        mwLog("[Proto] discoverModules")
        return try await withThrowingTaskGroup(of: MWModuleInfo.self) { group in
            for module in MWModule.allCases {
                group.addTask {
                    try await self.readModuleInfo(module)
                }
            }
            var result: [MWModule: MWModuleInfo] = [:]
            for try await info in group {
                result[info.module] = info
            }
            return result
        }
    }

    private func readModuleInfo(_ module: MWModule) async throws -> MWModuleInfo {
        let response = try await read(module, 0x00)
        // Response layout: [module, 0x80, impl, rev, extra...]
        let impl: UInt8 = response.count > 2 ? response[2] : 0xFF
        let rev: UInt8  = response.count > 3 ? response[3] : 0x00
        let extra: [UInt8] = response.count > 4
            ? Array(response[response.index(response.startIndex, offsetBy: 4)...])
            : []
        return MWModuleInfo(module: module, implementation: impl, revision: rev, extra: extra)
    }

    // MARK: - Routing

    private func route(packet: Data) {
        guard packet.count >= 2 else { return }
        let moduleId     = packet[0]
        let registerByte = packet[1]
        let isRead       = (registerByte & 0x80) != 0
        let normalized   = registerByte & 0x3F
        let key          = ModuleRegisterKey(module: moduleId, register: normalized)
        mwLog("[Proto] read and route: module=\(String(format: "%02X", moduleId)) register=\(String(format: "%02X", registerByte)) data=\(packet.dropFirst(2).map { String(format: "%02X", $0) })) isRead=\(isRead) [\(packet.map { String(format: "%02X", $0) }.joined(separator: " "))]")

        if isRead {
            if var waiters = readWaiters[key], !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                readWaiters[key] = waiters.isEmpty ? nil : waiters
                waiter.continuation.resume(returning: packet)
            }
        } else {
            // Deliver to one-shot notify waiters first (e.g. I2C/SPI read responses)
            if var waiters = notifyWaiters[key], !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                notifyWaiters[key] = waiters.isEmpty ? nil : waiters
                waiter.continuation.resume(returning: packet)
            }
            // Also deliver to ongoing notification streams (e.g. streaming sensors)
            notifyStreams[key]?.continuation.yield(packet)
        }
    }

    private func terminate(with error: Error) {
        mwLog("[Proto] terminate: \(error.localizedDescription)")
        failAllWaiters(with: error)
        onUnexpectedDisconnect?(error)
    }

    private func failAllWaiters(with error: Error) {
        for waiters in readWaiters.values {
            waiters.forEach { $0.continuation.resume(throwing: error) }
        }
        readWaiters.removeAll()
        for waiters in notifyWaiters.values {
            waiters.forEach { $0.continuation.resume(throwing: error) }
        }
        notifyWaiters.removeAll()
        tombstonedWaiterIDs.removeAll()
        notifyStreams.values.forEach { $0.continuation.finish(throwing: error) }
        notifyStreams.removeAll()
    }
}

// MARK: - MWPacket helper (variadic payload overload)

extension MWPacket {
    static func read(_ module: MWModule, _ register: UInt8, _ payload: [UInt8]) -> Data {
        Data([module.rawValue, register | 0x80] + payload)
    }

    static func command(_ module: MWModule, _ register: UInt8, _ payload: [UInt8]) -> Data {
        Data([module.rawValue, register] + payload)
    }
}
