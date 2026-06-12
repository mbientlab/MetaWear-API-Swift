import SwiftUI
import SwiftData

@main
struct MetaWearApp: App {

    @State private var appStore: AppStore
    private let containers: AppContainers

    init() {
        do {
            let containers = try AppModelContainer.makeShared()
            self.containers = containers
            _appStore = State(initialValue: AppStore(containers: containers))
        } catch {
            fatalError("Failed to create model containers: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appStore)
                .modelContainer(containers.cloud)
        }
    }
}
