import Foundation
import MetaWear

// Top-level async entry via Task + RunLoop.
// RunLoop.main.run() keeps the process alive for CoreBluetooth callbacks
// (CBCentralManager is initialised on the main queue).

Task { @MainActor in
    do {
        try await MetaWearDemo.run()
    } catch {
        print("Demo failed: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
