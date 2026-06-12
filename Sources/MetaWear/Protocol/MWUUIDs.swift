@preconcurrency import CoreBluetooth

public enum MWUUIDs {
    // MARK: - MetaWear custom service
    public static let service    = CBUUID(string: "326A9000-85CB-9195-D9DD-464CFBBAE75A")
    public static let command    = CBUUID(string: "326A9001-85CB-9195-D9DD-464CFBBAE75A")
    public static let notify     = CBUUID(string: "326A9006-85CB-9195-D9DD-464CFBBAE75A")

    // MARK: - Standard BLE Device Information Service (0x180A)
    public static let disService          = CBUUID(string: "180A")
    public static let firmwareRevision    = CBUUID(string: "2A26")
    public static let modelNumber         = CBUUID(string: "2A24")
    public static let hardwareRevision    = CBUUID(string: "2A27")
    public static let manufacturerName    = CBUUID(string: "2A29")
    public static let serialNumber        = CBUUID(string: "2A25")

    // MARK: - Standard Battery Service (0x180F)
    public static let batteryService      = CBUUID(string: "180F")
    public static let batteryLevel        = CBUUID(string: "2A19")

    // Note: the Generic Access Service (0x1800) and its Device Name
    // characteristic (0x2A00) are intentionally omitted. Apple's CoreBluetooth
    // filters both 0x1800 and 0x1801 from service discovery on iOS/macOS, so
    // they cannot be read by third-party apps. Use `CBPeripheral.name` (cached
    // by the OS from scan/connect metadata) for the advertised name.
}
