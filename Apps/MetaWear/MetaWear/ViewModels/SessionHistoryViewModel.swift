import Foundation
import Observation
import MetaWearPersistence

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
