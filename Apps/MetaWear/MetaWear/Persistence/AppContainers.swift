import SwiftData

struct AppContainers {
    /// CloudKit-backed, local-first store for lightweight device bookmarks.
    ///
    /// This container intentionally owns only `RememberedDevice`; session
    /// samples never enter CloudKit.
    let cloud: ModelContainer
    /// Local-only store for high-volume app data: logs, sessions, and samples.
    let local: ModelContainer
}
