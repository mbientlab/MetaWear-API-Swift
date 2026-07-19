import Foundation
import SwiftData
import Testing
import MetaWear
import MetaWearPersistence
@testable import MetaWearApp

/// End-to-end group capture against the simulated fleet: real SDK
/// connects, real logger round-trips through `DemoBLETransport`, real
/// SwiftData persistence — only the radio is fake. This is the regression
/// net for the whole MetaBase-style flow (start N boards → stop & download
/// N boards) before it ever touches hardware.
@Suite("GroupCaptureCoordinator — demo fleet")
@MainActor
struct GroupCaptureCoordinatorTests {

    private func makeRig() throws -> (AppStore, GroupCaptureCoordinator, [GroupCaptureCoordinator.Member]) {
        let containers = try AppModelContainer.makeShared(inMemory: true)
        let appStore = AppStore(containers: containers)
        let members = appStore.demoDevices.prefix(2).map {
            GroupCaptureCoordinator.Member(
                device: $0,
                name: DemoMode.name(for: $0.identifier) ?? "Demo"
            )
        }
        return (appStore, appStore.groupCapture, Array(members))
    }

    private let accelSelection = [
        SensorSelection(id: .accelerometer, hz: SensorKey.accelerometer.defaultHz, range: 2)
    ]

    @Test func startAllStartsEveryBoardAndDisconnects() async throws {
        let (appStore, coordinator, members) = try makeRig()

        await coordinator.startAll(members: members, selections: accelSelection)

        for board in coordinator.boards {
            #expect(board.phase == .logging, "\(board.name): \(board.phase)")
        }
        // One group-tagged record per board, all sharing ONE groupID.
        let records = appStore.pendingLogSessions.filter { $0.groupID != nil }
        #expect(records.count == members.count)
        #expect(Set(records.map(\.groupID)).count == 1)
        #expect(Set(records.map(\.deviceID)).count == members.count)
        // The walk owns its connections: boards are released afterwards.
        for member in members {
            #expect(await member.device.state == .disconnected)
        }
    }

    @Test func stopAndDownloadAllSavesGroupTaggedNamedSessions() async throws {
        let (appStore, coordinator, members) = try makeRig()

        await coordinator.startAll(members: members, selections: accelSelection)
        // Let the demo boards "record" long enough to bank entries.
        try await Task.sleep(for: .seconds(2))
        await coordinator.stopAndDownloadAll(members: members)

        for board in coordinator.boards {
            guard case .saved(let count) = board.phase else {
                Issue.record("\(board.name) ended \(board.phase), expected .saved")
                continue
            }
            #expect(count >= 1)
        }
        // No pending records remain; the fleet signal clears.
        #expect(appStore.pendingLogSessions.filter { $0.groupID != nil }.isEmpty)

        // Saved sessions carry the full attribution: name, count, ONE
        // shared groupID, distinct boards.
        let sessions = try await appStore.persistence.fetchAllSessions()
        #expect(sessions.count == members.count)
        #expect(Set(sessions.compactMap(\.groupID)).count == 1)
        #expect(Set(sessions.map(\.deviceID)).count == members.count)
        for session in sessions {
            #expect(session.deviceName?.hasPrefix("Simulated MetaWear") == true)
            #expect(session.sampleCount > 0)
        }
    }

    @Test func boardWithExistingPendingSessionIsSkippedOnStart() async throws {
        let (appStore, coordinator, members) = try makeRig()
        let occupied = members[0]

        // Board 0 already carries a solo session.
        let record = LogSessionRecord(
            deviceID: occupied.device.identifier,
            sensorKind: "accelerometer",
            configJSON: "{}",
            loggerKey: "existing"
        )
        appStore.containers.local.mainContext.insert(record)
        try appStore.containers.local.mainContext.save()
        appStore.refreshPendingLogSessions()

        await coordinator.startAll(members: members, selections: accelSelection)

        #expect(coordinator.boards[0].phase == .skipped("Already has a session — download it first"))
        #expect(coordinator.boards[1].phase == .logging)
        // The occupied board's record is untouched and NOT group-tagged.
        #expect(appStore.pendingLogSessions.first {
            $0.deviceID == occupied.device.identifier && $0.loggerKey == "existing"
        }?.groupID == nil)
    }

    /// A board whose peripheral iOS can't resolve (foreign-host UUID from
    /// a CloudKit-synced record, never seen here) fails its connect
    /// INSTANTLY — and the cleanup path must not issue a disconnect for a
    /// peripheral the central never registered: that parks a continuation
    /// nothing resumes, wedging the walk with isBusy stuck true forever.
    /// Adversarial review found the hang; this pins the fix.
    @Test(.timeLimit(.minutes(1)))
    func unresolvableBoardFailsFastWithoutWedgingTheWalk() async throws {
        let (appStore, coordinator, members) = try makeRig()
        let phantom = GroupCaptureCoordinator.Member(
            device: appStore.scanner.device(forKnownIdentifier: UUID()),
            name: "Phantom"
        )

        await coordinator.startAll(
            members: [phantom, members[0]], selections: accelSelection
        )

        #expect(coordinator.isBusy == false)
        if case .failed = coordinator.boards[0].phase {} else {
            Issue.record("phantom ended \(coordinator.boards[0].phase), expected .failed")
        }
        // The walk moved past the phantom: the real board still started.
        #expect(coordinator.boards[1].phase == .logging)
    }

    @Test func boardWithNothingToDownloadIsSkippedOnCollect() async throws {
        // The appStore must stay named and alive: the coordinator's
        // back-reference is `unowned` (in the app, AppStore owns the
        // coordinator for the process lifetime) — discarding it with `_`
        // deallocates it mid-walk and aborts on the unowned load.
        let (appStore, coordinator, members) = try makeRig()

        // Collect without ever starting: fresh demo boards hold no entries
        // and aren't logging — the catch-all should skip, not fail.
        await coordinator.stopAndDownloadAll(members: [members[0]])

        #expect(coordinator.boards[0].phase == .skipped("Nothing to download"))
        #expect(appStore.pendingLogSessions.isEmpty)
    }
}
