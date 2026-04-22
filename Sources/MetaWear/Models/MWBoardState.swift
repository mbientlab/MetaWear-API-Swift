import Foundation

// MARK: - MWBoardState
//
// Persisted snapshot of a MetaWear board's post-initialize state. Lets a client
// skip the full re-discovery handshake on reconnect when the firmware revision
// and hardware revision still match.
//
// This is a deliberately Swift-native shape (JSON via Codable) rather than the
// C++ SDK's binary blob. The C++ format is tied to internal struct layout and
// isn't a stable on-disk format. Callers who need C++ interop should keep the
// C++ SDK alongside; everyone else should prefer this.
//
// Wire format: JSON. Keys are stable. The `schemaVersion` integer is bumped on
// backwards-incompatible changes so callers can discard old caches.

public struct MWBoardState: Sendable, Equatable, Codable {
    /// Bump on any breaking layout change.
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let deviceInformation: MWDeviceInformation
    public let modules: [MWModuleInfo]
    /// Wall-clock reference: the `Date` at which the board's logging tick was 0.
    /// `nil` when the logging module is not present or the tick reference wasn't read.
    public let logReferenceDate: Date?

    public init(deviceInformation: MWDeviceInformation,
                modules: [MWModuleInfo],
                logReferenceDate: Date?) {
        self.schemaVersion    = MWBoardState.currentSchemaVersion
        self.deviceInformation = deviceInformation
        self.modules          = modules
        self.logReferenceDate = logReferenceDate
    }

    // MARK: Dictionary view

    /// Modules keyed by module opcode for O(1) lookup.
    public var modulesByOpcode: [MWModule: MWModuleInfo] {
        Dictionary(uniqueKeysWithValues: modules.map { ($0.module, $0) })
    }

    // MARK: Validity against a live board

    /// Whether this state is safe to reuse with a board reporting `liveInfo` without
    /// rerunning module discovery. Matches C++ `metawearboard`'s firmware-match check.
    public func isCompatible(with liveInfo: MWDeviceInformation) -> Bool {
        deviceInformation.firmwareRevision == liveInfo.firmwareRevision
            && deviceInformation.hardwareRevision == liveInfo.hardwareRevision
            && deviceInformation.modelNumber == liveInfo.modelNumber
    }

    // MARK: Serialization

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode to JSON.
    public func encode() throws -> Data {
        try MWBoardState.encoder.encode(self)
    }

    /// Decode a previously-encoded state. Throws `MWError.operationFailed` if the
    /// schema is newer than this SDK supports or the JSON is malformed.
    public static func decode(_ data: Data) throws -> MWBoardState {
        let state: MWBoardState
        do {
            state = try decoder.decode(MWBoardState.self, from: data)
        } catch {
            throw MWError.operationFailed("Failed to decode board state: \(error.localizedDescription)")
        }
        if state.schemaVersion > currentSchemaVersion {
            throw MWError.operationFailed(
                "Board state schema \(state.schemaVersion) is newer than supported (\(currentSchemaVersion))"
            )
        }
        return state
    }
}
