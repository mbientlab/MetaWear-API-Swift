import Foundation
import SwiftData

@Model
final class LogSessionRecord {
    // CloudKit-compatible: no unique constraint, every stored property is
    // optional or defaulted. Uniqueness of `id` is guaranteed by the app
    // assigning a fresh UUID per session; lookups use a UUID predicate.
    var id: UUID = UUID()
    var deviceID: UUID = UUID()
    var sensorKind: String = ""
    var configJSON: String = ""
    var loggerKey: String = ""
    var startDate: Date = Date.distantPast
    /// Default must equal `Status.running.rawValue`.
    var statusRaw: String = "running"
    /// JSON-encoded `MWPolledLoggerHandles` for `temperature` / `humidity`
    /// sessions where the board-side timer + event + logger chain must be
    /// remembered across app restarts. Nil for natively-loggable sensors,
    /// whose registry can be recovered by module + register match alone.
    var polledHandlesJSON: String?

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        deviceID: UUID,
        sensorKind: String,
        configJSON: String,
        loggerKey: String,
        startDate: Date = .now,
        status: Status = .running,
        polledHandlesJSON: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.sensorKind = sensorKind
        self.configJSON = configJSON
        self.loggerKey = loggerKey
        self.startDate = startDate
        self.statusRaw = status.rawValue
        self.polledHandlesJSON = polledHandlesJSON
    }

    enum Status: String, Sendable {
        case running
        case stopped
        case downloaded
        case failed
    }
}
