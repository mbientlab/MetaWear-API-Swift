import Foundation
import SwiftData

@Model
final class RememberedDevice {
    var peripheralUUID: UUID = UUID()
    var name: String = ""
    var macAddress: String?
    var lastConnected: Date = Date.distantPast
    var serialNumber: String?
    var firmwareRevision: String?
    var modelNumber: String?

    init(
        peripheralUUID: UUID,
        name: String,
        macAddress: String? = nil,
        lastConnected: Date = .now,
        serialNumber: String? = nil,
        firmwareRevision: String? = nil,
        modelNumber: String? = nil
    ) {
        self.peripheralUUID = peripheralUUID
        self.name = name
        self.macAddress = macAddress
        self.lastConnected = lastConnected
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.modelNumber = modelNumber
    }
}
