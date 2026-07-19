import Foundation
import Testing
@testable import MetaWearApp

/// Covers `AppStore.foreignLogDecision` — the pure table deciding whether a
/// connected board carries a recoverable session this phone doesn't own.
@MainActor
@Suite("Foreign-log decision")
struct ForeignLogDecisionTests {

    @Test
    func localPendingRecordAlwaysLeavesTheBoardAlone() {
        #expect(AppStore.foreignLogDecision(
            entryCount: 500, hasActiveLoggers: true,
            isLoggingEnabled: true, hasLocalPendingRecord: true
        ) == .leaveAlone)
    }

    @Test
    func loggersWithEntriesSurface() {
        #expect(AppStore.foreignLogDecision(
            entryCount: 500, hasActiveLoggers: true,
            isLoggingEnabled: false, hasLocalPendingRecord: false
        ) == .surface(isActivelyLogging: false))
    }

    @Test
    func activeLoggingWithZeroEntriesSurfaces() {
        // THE case the old matrix missed: an actively-logging MMS whose
        // first flash page is still buffering reads LOG_LENGTH == 0. The
        // enabled flag must carry the detection.
        #expect(AppStore.foreignLogDecision(
            entryCount: 0, hasActiveLoggers: true,
            isLoggingEnabled: true, hasLocalPendingRecord: false
        ) == .surface(isActivelyLogging: true))
    }

    @Test
    func armedButNeverStartedLoggersAreLeftAlone() {
        // Loggers configured, nothing recorded, sampling off — no data to
        // recover, and the wiring might belong to someone about to use it.
        #expect(AppStore.foreignLogDecision(
            entryCount: 0, hasActiveLoggers: true,
            isLoggingEnabled: false, hasLocalPendingRecord: false
        ) == .leaveAlone)
    }

    @Test
    func entriesWithoutLoggersClearSilently() {
        // No logger subscriptions = no decoder anywhere = guaranteed
        // garbage (e.g. the MMS post-clear sentinel).
        #expect(AppStore.foreignLogDecision(
            entryCount: 1, hasActiveLoggers: false,
            isLoggingEnabled: false, hasLocalPendingRecord: false
        ) == .silentClear)
    }

    @Test
    func cleanBoardIsANoOp() {
        #expect(AppStore.foreignLogDecision(
            entryCount: 0, hasActiveLoggers: false,
            isLoggingEnabled: false, hasLocalPendingRecord: false
        ) == .leaveAlone)
    }

    @Test
    func failedLoggerEnumerationErsOnSurfacing() {
        // Can't prove the entries are garbage — never clear them.
        #expect(AppStore.foreignLogDecision(
            entryCount: 500, hasActiveLoggers: nil,
            isLoggingEnabled: false, hasLocalPendingRecord: false
        ) == .surface(isActivelyLogging: false))
        #expect(AppStore.foreignLogDecision(
            entryCount: 0, hasActiveLoggers: nil,
            isLoggingEnabled: true, hasLocalPendingRecord: false
        ) == .surface(isActivelyLogging: true))
        #expect(AppStore.foreignLogDecision(
            entryCount: 0, hasActiveLoggers: nil,
            isLoggingEnabled: false, hasLocalPendingRecord: false
        ) == .leaveAlone)
    }
}
