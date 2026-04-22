/// Errors thrown by `MWPersistenceStore`.
public enum MWPersistenceError: Error, Sendable, Equatable {
    /// Attempted to save a session with zero samples.
    case emptySampleSet
    /// The stored `sensorKind` does not match the requested type's `persistenceKind`.
    case kindMismatch(stored: String, requested: String)
    /// A session with the given `PersistentIdentifier` was not found in the store.
    case sessionNotFound
}
