import SwiftData
import MetaWear
import Foundation

// MARK: - MWPersistenceStore

/// Actor-isolated store for persisted MetaWear log sessions.
///
/// Uses the `@ModelActor` macro which pins a dedicated `ModelContext` to the actor's
/// serial executor — the correct Swift 6 pattern for background SwiftData access.
///
/// All methods that look up a session by ID use `FetchDescriptor` with a UUID predicate,
/// which is safe across context saves and deletes (unlike `modelContext.model(for:)`).
///
/// ### Typical usage
/// ```swift
/// // App startup — create the container once
/// let container = try MWPersistenceStore.makeContainer()
/// let store = MWPersistenceStore(modelContainer: container)
///
/// // After downloading logs:
/// let snapshot = try await store.saveSession(
///     deviceID: device.identifier,
///     deviceInfo: device.deviceInfo!,
///     sensorKind: CartesianFloat.persistenceKind,
///     samples: downloadedSamples)
///
/// // Later — list sessions for this device:
/// let sessions = try await store.fetchSessions(deviceID: device.identifier)
/// ```
@ModelActor
public actor MWPersistenceStore {

    // MARK: - Container factory

    /// Create a `ModelContainer` for the full MetaWear persistence schema.
    ///
    /// - Parameter inMemory: Pass `true` for unit tests and SwiftUI previews.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([MWSessionRecord.self, MWSampleRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: config)
    }

    // MARK: - Save

    /// Persist a completed download session.
    ///
    /// - Parameters:
    ///   - deviceID: The `MetaWearDevice.identifier` (CoreBluetooth peripheral UUID).
    ///   - deviceInfo: Device information read during `connect()`.
    ///   - sensorKind: `S.persistenceKind` — the discriminator stored on the session record.
    ///   - samples: The typed logged samples returned by `downloadLogs`.
    /// - Returns: A `MWSessionSnapshot` describing the newly created session.
    /// - Throws: `MWPersistenceError.emptySampleSet` if `samples` is empty.
    public func saveSession<S: MWPersistable>(
        deviceID: UUID,
        deviceInfo: MWDeviceInformation,
        sensorKind: String,
        samples: [MWLoggedSample<S>]
    ) throws -> MWSessionSnapshot {
        guard !samples.isEmpty else { throw MWPersistenceError.emptySampleSet }

        let session = MWSessionRecord(
            deviceID:       deviceID,
            sensorKind:     sensorKind,
            startDate:      samples.first!.date,
            endDate:        samples.last!.date,
            deviceSerial:   deviceInfo.serialNumber,
            deviceModel:    deviceInfo.modelNumber,
            deviceFirmware: deviceInfo.firmwareRevision
        )
        modelContext.insert(session)

        for logged in samples {
            let v = logged.value.persistenceValues
            let record = MWSampleRecord(
                date:     logged.date,
                tickMs:   logged.tickMs,
                f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3,
                accuracy: v.accuracy
            )
            record.session = session
            modelContext.insert(record)
        }
        try modelContext.save()
        return MWSessionSnapshot(record: session)
    }

    // MARK: - Fetch sessions

    /// All sessions for one device, sorted newest-first.
    public func fetchSessions(deviceID: UUID) throws -> [MWSessionSnapshot] {
        var descriptor = FetchDescriptor<MWSessionRecord>(
            predicate: #Predicate { $0.deviceID == deviceID },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.samples]
        return try modelContext.fetch(descriptor).map(MWSessionSnapshot.init)
    }

    /// All sessions across all devices, sorted newest-first.
    public func fetchAllSessions() throws -> [MWSessionSnapshot] {
        var descriptor = FetchDescriptor<MWSessionRecord>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.samples]
        return try modelContext.fetch(descriptor).map(MWSessionSnapshot.init)
    }

    // MARK: - Fetch samples

    /// Reconstruct typed samples from a previously saved session.
    ///
    /// - Parameters:
    ///   - sessionID: The `MWSessionSnapshot.id` returned by `fetchSessions` or `saveSession`.
    ///   - type: The expected sample type. Must match the session's `sensorKind`.
    /// - Throws: `MWPersistenceError.sessionNotFound` or `MWPersistenceError.kindMismatch`.
    public func fetchSamples<S: MWPersistable>(
        sessionID: UUID,
        as type: S.Type
    ) throws -> [MWLoggedSample<S>] {
        let session = try requireSession(id: sessionID)
        guard session.sensorKind == S.persistenceKind else {
            throw MWPersistenceError.kindMismatch(
                stored: session.sensorKind,
                requested: S.persistenceKind
            )
        }
        return session.samples
            .sorted { $0.tickMs < $1.tickMs }
            .map { r in
                MWLoggedSample(
                    date:   r.date,
                    tickMs: r.tickMs,
                    value:  S.from(f0: r.f0, f1: r.f1, f2: r.f2, f3: r.f3, accuracy: r.accuracy)
                )
            }
    }

    // MARK: - Export

    /// Build a `MWDataTable` (suitable for CSV export) from a persisted session.
    ///
    /// - Parameters:
    ///   - sessionID: The `MWSessionSnapshot.id` of the session to export.
    ///   - type: The sample type — must match the session's `sensorKind`.
    public func exportTable<S: MWPersistable>(
        sessionID: UUID,
        as type: S.Type
    ) throws -> MWDataTable {
        let samples = try fetchSamples(sessionID: sessionID, as: type)
        return MWDataTable.from(logged: samples, name: S.persistenceKind)
    }

    // MARK: - Delete

    /// Delete one session (and all its samples via cascade).
    public func deleteSession(id: UUID) throws {
        guard let session = try fetchRecord(id: id) else { return }
        modelContext.delete(session)
        try modelContext.save()
    }

    /// Delete all sessions for a given device.
    public func deleteAllSessions(for deviceID: UUID) throws {
        try modelContext.delete(
            model: MWSessionRecord.self,
            where: #Predicate { $0.deviceID == deviceID }
        )
        try modelContext.save()
    }

    /// Delete every session in the store.
    public func deleteAll() throws {
        try modelContext.delete(model: MWSessionRecord.self)
        try modelContext.save()
    }

    // MARK: - Private helpers

    /// Fetch a session record by its stable UUID using FetchDescriptor.
    /// Safe to call after deletions — won't return invalidated model objects.
    private func fetchRecord(id: UUID) throws -> MWSessionRecord? {
        var descriptor = FetchDescriptor<MWSessionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        descriptor.relationshipKeyPathsForPrefetching = [\.samples]
        return try modelContext.fetch(descriptor).first
    }

    private func requireSession(id: UUID) throws -> MWSessionRecord {
        guard let session = try fetchRecord(id: id) else {
            throw MWPersistenceError.sessionNotFound
        }
        return session
    }
}
