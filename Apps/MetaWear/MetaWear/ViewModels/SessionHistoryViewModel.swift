import Foundation
import Observation
import MetaWearPersistence

/// Minimal view model for the session-history screen.
///
/// Listing is driven directly by SwiftData queries in the view; this type owns
/// actions that need async persistence calls and error presentation.
@Observable
@MainActor
final class SessionHistoryViewModel {
    let store: MWPersistenceStore

    var lastError: AppError?

    init(store: MWPersistenceStore) {
        self.store = store
    }

    func deleteSession(id: UUID) async {
        do {
            try await store.deleteSession(id: id)
        } catch {
            lastError = AppError(error: error)
        }
    }
}
