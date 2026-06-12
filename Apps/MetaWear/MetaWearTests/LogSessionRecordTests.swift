import Testing
import SwiftData
import Foundation
@testable import MetaWearApp

@Suite("LogSessionRecord persistence")
@MainActor
struct LogSessionRecordTests {

    @Test func roundTripsThroughSwiftData() throws {
        let schema = Schema([LogSessionRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
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
