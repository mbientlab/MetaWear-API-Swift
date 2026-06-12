import Testing
import SwiftData
import Foundation
@testable import MetaWearApp

@Suite("LogSessionRecord persistence")
@MainActor
struct LogSessionRecordTests {

    @Test func roundTripsThroughSwiftData() throws {
        // Use the app's own container factory (in-memory) instead of building
        // an ad-hoc single-model container. On the iOS 26 simulator, creating
        // a second container whose schema partially overlaps the host app's
        // already-loaded 4-model schema throws
        // `SwiftDataError.loadIssueModelContainer` — the full-schema factory
        // matches what the app registered and loads cleanly.
        let container = try AppModelContainer.makeShared(inMemory: true).local
        let context = container.mainContext

        let id = UUID()
        let record = LogSessionRecord(
            id: id,
            deviceID: UUID(),
            sensorKind: "accelerometer",
            configJSON: "{\"hz\":50}",
            loggerKey: "acceleration",
            startDate: .now,
            status: .running
        )
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LogSessionRecord>(
            predicate: #Predicate { $0.id == id }
        ))
        #expect(fetched.count == 1)
        #expect(fetched.first?.status == .running)

        fetched.first?.status = .downloaded
        try context.save()

        let again = try context.fetch(FetchDescriptor<LogSessionRecord>(
            predicate: #Predicate { $0.id == id }
        ))
        #expect(again.first?.status == .downloaded)
    }
}
