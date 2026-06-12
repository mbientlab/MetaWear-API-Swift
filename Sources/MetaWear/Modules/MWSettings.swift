import Foundation

// MARK: - Settings module (0x11)

/// Commands for the MetaWear settings module.
/// Controls device name, advertising, TX power, and connection parameters.
public enum MWSettings {

    // MARK: - Device name

    /// Maximum length of a BLE advertising name, in ASCII bytes.
    /// Matches the limit the C++ reference SDK enforces at the validator.
    public static let maxDeviceNameLength = 26

    /// Characters allowed in a MetaWear BLE advertising name: ASCII letters,
    /// digits, underscore, hyphen, and space. Matches the C++ reference SDK.
    public static let validDeviceNameCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_- ")

    /// True when `proposed` is a valid BLE advertising name:
    /// - non-empty
    /// - ≤ `maxDeviceNameLength` ASCII bytes
    /// - only contains characters in `validDeviceNameCharacters`
    ///
    /// Matches `MetaWear.isNameValid` from the reference Combine SDK.
    public static func isNameValid(_ proposed: String) -> Bool {
        if proposed.isEmpty { return false }
        guard proposed.unicodeScalars.allSatisfy({ validDeviceNameCharacters.contains($0) }),
              let encoded = proposed.data(using: .ascii)
        else { return false }
        return encoded.count <= maxDeviceNameLength
    }

    /// Set the BLE advertising name (max 26 ASCII bytes).
    /// The new name takes effect after the next advertisement cycle.
    ///
    /// Use `init(validating:)` to reject invalid names up front; the plain
    /// `init(_:)` truncates to `maxDeviceNameLength` bytes and performs no
    /// character filtering (mirrors the C++ SDK's low-level behaviour).
    public struct SetDeviceName: MWCommand, Sendable {
        public let name: String

        public init(_ name: String) {
            self.name = name
        }

        /// Validating initializer. Throws `MWError.operationFailed` when
        /// `name` fails `MWSettings.isNameValid`.
        public init(validating name: String) throws {
            guard MWSettings.isNameValid(name) else {
                throw MWError.operationFailed("Invalid device name: \"\(name)\"")
            }
            self.name = name
        }

        public var commandData: Data {
            let nameBytes = Array(name.utf8.prefix(MWSettings.maxDeviceNameLength))
            return MWPacket.command(.settings, 0x01, nameBytes)
        }
    }

    // MARK: - TX power

    /// BLE transmit power level. Raw value is the radio output in dBm
    /// (signed) — passed verbatim to the firmware.
    public enum TXPower: Int8, Sendable, CaseIterable {
        /// +4 dBm — maximum strength, shortest battery life.
        case plus4  =  4
        /// 0 dBm — radio default.
        case zero   =  0
        /// -4 dBm.
        case minus4 = -4
        /// -8 dBm.
        case minus8 = -8
        /// -12 dBm.
        case minus12 = -12
        /// -16 dBm.
        case minus16 = -16
        /// -20 dBm — long-range mode at the cost of throughput.
        case minus20 = -20
        /// -40 dBm — proximity-only debug level.
        case minus40 = -40
    }

    /// Set the BLE radio transmit power. Takes effect immediately.
    public struct SetTXPower: MWCommand, Sendable {
        public let power: TXPower

        public init(_ power: TXPower) {
            self.power = power
        }

        public var commandData: Data {
            MWPacket.command(.settings, 0x03, [UInt8(bitPattern: power.rawValue)])
        }
    }

    // MARK: - Advertising interval

    /// BLE advertising type. Only honored on whitelist-capable boards
    /// (settings revision ≥ 6); older firmware silently ignores the extra byte.
    public enum BleAdType: UInt8, Sendable, CaseIterable {
        /// Connectable, undirected (scannable by anyone). Default.
        case connectableUndirected = 0
        /// Connectable, directed (only a specific central can connect — requires whitelist entry).
        case connectableDirected   = 1
    }

    /// Set the BLE advertising interval.
    ///
    /// - Parameters:
    ///   - intervalMs: Advertising interval in milliseconds (20–10240 ms). Encoded as units of 0.625 ms.
    ///   - timeoutSec: Advertising timeout in seconds (0 = advertise indefinitely).
    ///   - adType:     Optional advertising type byte appended when targeting a settings
    ///                 revision ≥ 6 board (whitelist-capable). `nil` preserves the legacy 4-byte command.
    public struct SetAdvertisingInterval: MWCommand, Sendable {
        public let intervalMs: UInt16
        public let timeoutSec: UInt8
        public let adType: BleAdType?

        public init(intervalMs: UInt16 = 417, timeoutSec: UInt8 = 0, adType: BleAdType? = nil) {
            self.intervalMs  = intervalMs
            self.timeoutSec  = timeoutSec
            self.adType      = adType
        }

        public var commandData: Data {
            // Encode interval in units of 0.625 ms
            let units = UInt16(Double(intervalMs) / 0.625)
            var payload: [UInt8] = [
                UInt8(units & 0xFF),
                UInt8(units >> 8),
                timeoutSec
            ]
            if let adType { payload.append(adType.rawValue) }
            return MWPacket.command(.settings, 0x02, payload)
        }
    }

    /// Force the board to begin BLE advertising immediately, rather than
    /// waiting for the next idle window.
    public struct StartAdvertising: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.settings, 0x05, []) }
    }

    // MARK: - Connection parameters

    /// Set BLE connection parameters.
    ///
    /// All interval values are in units of 1.25 ms (per Bluetooth spec).
    /// Typical values: min=6 (7.5 ms), max=24 (30 ms), latency=0, timeout=500 (5 s).
    ///
    /// - Parameters:
    ///   - minInterval: Minimum connection interval (units of 1.25 ms, range 6–3200).
    ///   - maxInterval: Maximum connection interval (units of 1.25 ms, range 6–3200).
    ///   - latency:     Slave latency (number of connection events the peripheral may skip).
    ///   - timeout:     Supervision timeout (units of 10 ms, range 10–3200).
    public struct SetConnectionParameters: MWCommand, Sendable {
        public let minInterval: UInt16
        public let maxInterval: UInt16
        public let latency: UInt16
        public let timeout: UInt16

        public init(
            minInterval: UInt16 = 6,
            maxInterval: UInt16 = 24,
            latency: UInt16     = 0,
            timeout: UInt16     = 500
        ) {
            self.minInterval = minInterval
            self.maxInterval = maxInterval
            self.latency     = latency
            self.timeout     = timeout
        }

        public var commandData: Data {
            func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
            return MWPacket.command(.settings, 0x09,
                le16(minInterval) + le16(maxInterval) + le16(latency) + le16(timeout)
            )
        }
    }

    // MARK: - Scan response
    //
    // Scan response payload per `SCAN_RESPONSE` (register 0x07) and
    // `PARTIAL_SCAN_RESPONSE` (register 0x08) in `settings_register.h`. The
    // full response may exceed a single BLE write; the firmware concatenates
    // it when the first 13 bytes go to register 0x08 and the remainder to
    // register 0x07.
    //
    // Python reference (`test_settings.py::test_set_scan_response`, 21-byte
    // payload `\x03\x03\xD8\xfe\x10\x16\xd8\xfe\x00\x12\x00\x6d\x62\x69\x65\x6e\x74\x6c\x61\x62\x00`):
    // ```
    // [0x11, 0x08, 0x03, 0x03, 0xd8, 0xfe, 0x10, 0x16, 0xd8, 0xfe, 0x00, 0x12, 0x00, 0x6d, 0x62],
    // [0x11, 0x07, 0x69, 0x65, 0x6e, 0x74, 0x6c, 0x61, 0x62, 0x00]
    // ```
    /// Program the BLE scan-response payload that the board returns to
    /// scanners. May expand into multiple BLE writes — see `commands`.
    public struct SetScanResponse: MWCommandSequence {
        public let payload: [UInt8]

        public init(_ payload: [UInt8]) {
            self.payload = payload
        }

        /// Ordered list of commands to send. Short payloads (≤ 13 bytes) emit a
        /// single write to register 0x07; larger payloads are split across
        /// register 0x08 (first 13 bytes) and register 0x07 (remainder).
        public var commands: [Data] {
            if payload.count <= 13 {
                return [MWPacket.command(.settings, 0x07, payload)]
            }
            let partial = Array(payload.prefix(13))
            let rest    = Array(payload.dropFirst(13))
            return [
                MWPacket.command(.settings, 0x08, partial),
                MWPacket.command(.settings, 0x07, rest)
            ]
        }
    }

    // MARK: - Battery state (settings revision ≥ 3)
    //
    // Register 0x0C (`BATTERY_STATE`) in `settings_register.h`. Wire request:
    // `[0x11, 0x8C]` (register 0x0C | READ 0x80). Response shape:
    // `[0x11, 0x8C, charge, volt_lo, volt_hi]`.
    //
    // The C++ `MblMwDataSignal` constructor enables the SILENT bit (0x40) on
    // readable signals at construction, but the production read path in the
    // Combine SDK calls `mbl_mw_datasignal_subscribe` *before*
    // `mbl_mw_datasignal_read` (see `Combine/Read.swift::_read`), and
    // `subscribe()` on a readable signal clears the silent bit (see
    // `datasignal.cpp::subscribe`). So the actual wire byte that ships in
    // production is `0x8C`, not `0xCC` — the `[0x11, 0xcc]` you see in
    // `test_settings.py::test_read_battery_state` only appears because the
    // unit test calls `datasignal_read` on a freshly-constructed signal
    // without going through the subscribe-first wrapper.
    //
    // The MMS firmware we target (settings revision 10, fw 1.6.x) silently
    // ignores `[0x11, 0xCC]` reads: no notification ever comes back, and the
    // host times out. `[0x11, 0x8C]` produces the response immediately.
    /// One-shot read of the battery charge percentage and voltage.
    /// Requires settings module revision ≥ 3.
    public struct ReadBatteryState: MWReadable {
        public typealias Sample = BatteryState

        public init() {}

        public let module: MWModule = .settings
        public let dataRegister: UInt8 = 0x0C
        public let packedDataRegister: UInt8? = nil

        public var readCommand: Data { MWPacket.read(.settings, 0x0C) }

        public func parseSample(from packet: Data) throws -> BatteryState {
            try MWPacketParser.parseBatteryState(packet)
        }
    }

    // MARK: - MAC address (settings revision ≥ 2)
    //
    // Register 0x0B (`MAC`) in `settings_register.h`. Unlike the battery
    // signal, tests exercise this via `datasignal_subscribe` + notification
    // rather than a read round-trip, but the readable fetch pattern produces
    // `[0x11, 0x8B]` (register 0x0B | READ). The firmware response starts
    // `[0x11, 0x8B, data_id, mac5, mac4, mac3, mac2, mac1, mac0]`; the MAC is
    // formatted in reverse-byte colon notation (e.g. `E8:C9:8F:52:7B:07`).
    //
    // Python reference (`test_settings.py::test_mac_address`): packet
    // `[0x11, 0x8b, 0x01, 0x07, 0x7b, 0x52, 0x8f, 0xc9, 0xe8]` → `"E8:C9:8F:52:7B:07"`.
    /// One-shot read of the board's BLE MAC address, formatted as a
    /// canonical colon-separated string (e.g. `"E8:C9:8F:52:7B:07"`).
    /// Requires settings module revision ≥ 2.
    public struct ReadMacAddress: MWReadable {
        public typealias Sample = String

        public init() {}

        public let module: MWModule = .settings
        public let dataRegister: UInt8 = 0x0B
        public let packedDataRegister: UInt8? = nil

        public var readCommand: Data { MWPacket.read(.settings, 0x0B) }

        public func parseSample(from packet: Data) throws -> String {
            try MWPacketParser.parseMacAddress(packet)
        }
    }

    // MARK: - Power / charge status (settings revision ≥ 5 with status flags)
    //
    // Registers 0x11 (`POWER_STATUS`) and 0x12 (`CHARGE_STATUS`). Both are
    // non-readable notification signals by default; `mark_readable()` is
    // applied in the C++ init only for the one-shot read path, so:
    //   - Streaming notification header: `[0x11, 0x11, value]` / `[0x11, 0x12, value]`
    //   - One-shot read command:          `[0x11, 0x91]`        / `[0x11, 0x92]`
    //
    // Python reference (`test_settings.py::test_read_current_power` /
    // `test_read_current_charge`): read emits `[0x11, 0x91]` and `[0x11, 0x92]`.

    /// One-shot read of the current power-supply status (0 = not powered, 1 = powered).
    /// Only valid on boards whose settings module advertises the power-status bit
    /// (`module_info.extra[0] & 0x01`, revision ≥ 5).
    public struct ReadPowerStatus: MWReadable {
        public typealias Sample = UInt8

        public init() {}

        public let module: MWModule = .settings
        public let dataRegister: UInt8 = 0x11
        public let packedDataRegister: UInt8? = nil

        public var readCommand: Data { MWPacket.read(.settings, 0x11) }

        public func parseSample(from packet: Data) throws -> UInt8 {
            guard packet.count >= 3 else {
                throw MWError.operationFailed("Power status packet too short: \(packet.count) bytes")
            }
            return packet[2]
        }
    }

    /// One-shot read of the current charging status (0 = not charging, 1 = charging).
    /// Only valid on boards whose settings module advertises the charge-status bit
    /// (`module_info.extra[0] & 0x02`, revision ≥ 5).
    public struct ReadChargeStatus: MWReadable {
        public typealias Sample = UInt8

        public init() {}

        public let module: MWModule = .settings
        public let dataRegister: UInt8 = 0x12
        public let packedDataRegister: UInt8? = nil

        public var readCommand: Data { MWPacket.read(.settings, 0x12) }

        public func parseSample(from packet: Data) throws -> UInt8 {
            guard packet.count >= 3 else {
                throw MWError.operationFailed("Charge status packet too short: \(packet.count) bytes")
            }
            return packet[2]
        }
    }

    // MARK: - Whitelist filter (settings revision ≥ 6)
    //
    // Register 0x13 (`WHITELIST_FILTER_MODE`). Mirrors C++
    // `mbl_mw_settings_set_whitelist_filter_mode` and `MblMwWhitelistFilter`.
    // Silently ignored by firmware < revision 6.

    /// Behavior of the BLE whitelist filter (`MblMwWhitelistFilter`).
    public enum WhitelistFilterMode: UInt8, Sendable, CaseIterable {
        /// Accept scan + connection requests from any central (whitelist disabled). Default.
        case allowFromAny                  = 0
        /// Scan requests honored from any central; connection requests restricted to whitelist.
        case scanRequestsOnly              = 1
        /// Scan requests restricted to whitelist; connection requests honored from any central.
        case connectionRequestsOnly        = 2
        /// Both scan and connection requests restricted to whitelist entries.
        case scanAndConnectionRequests     = 3
    }

    /// Configure how the board's whitelist restricts incoming BLE traffic.
    /// Requires settings module revision ≥ 6.
    public struct SetWhitelistFilterMode: MWCommand, Sendable {
        public let mode: WhitelistFilterMode

        public init(_ mode: WhitelistFilterMode) { self.mode = mode }

        public var commandData: Data {
            MWPacket.command(.settings, 0x13, [mode.rawValue])
        }
    }

    // MARK: - Whitelist address table (settings revision ≥ 6)
    //
    // Register 0x14 (`WHITELIST_ADDRESSES`). Mirrors C++
    // `mbl_mw_settings_add_whitelist_address` and the `MblMwBtleAddress` struct:
    //   { uint8_t address_type; uint8_t address[6]; }   // address is LSB-first
    // Wire format: `[0x11, 0x14, index, address_type, b0, b1, b2, b3, b4, b5]`.

    /// A BLE MAC address in the format accepted by the whitelist register.
    ///
    /// `bytesLSBFirst` is the raw on-wire order — the canonical `AA:BB:CC:DD:EE:FF`
    /// display form is the reverse. Use `parse(_:type:)` to build from display form.
    public struct BluetoothAddress: Sendable, Equatable {
        /// BLE address type (`MblMwBtleAddress.address_type`).
        public enum AddressType: UInt8, Sendable, CaseIterable {
            /// Globally unique public address assigned by the manufacturer.
            case `public` = 0
            /// Random/resolvable address (Bluetooth privacy feature).
            case random  = 1
        }

        public let type: AddressType
        /// 6 raw MAC bytes, LSB first (matches `MblMwBtleAddress.address[6]`).
        public let bytesLSBFirst: [UInt8]

        /// - Parameter bytesLSBFirst: Must be exactly 6 bytes.
        public init(type: AddressType, bytesLSBFirst: [UInt8]) {
            precondition(bytesLSBFirst.count == 6, "BluetoothAddress requires exactly 6 bytes")
            self.type           = type
            self.bytesLSBFirst  = bytesLSBFirst
        }

        /// Parse a colon- or hyphen-separated MAC string (canonical display order,
        /// e.g. `"E8:C9:8F:52:7B:07"`). Bytes are reversed to match wire (LSB-first) order.
        public static func parse(_ mac: String, type: AddressType = .public) throws -> BluetoothAddress {
            let separators = CharacterSet(charactersIn: ":-")
            let parts = mac.components(separatedBy: separators)
            guard parts.count == 6 else {
                throw MWError.operationFailed("MAC must have 6 octets: \"\(mac)\"")
            }
            var displayBytes: [UInt8] = []
            displayBytes.reserveCapacity(6)
            for part in parts {
                guard part.count == 2, let b = UInt8(part, radix: 16) else {
                    throw MWError.operationFailed("Invalid MAC octet \"\(part)\" in \"\(mac)\"")
                }
                displayBytes.append(b)
            }
            // Display order is byte5:byte4:…:byte0; wire is byte0:byte1:…:byte5.
            return BluetoothAddress(type: type, bytesLSBFirst: Array(displayBytes.reversed()))
        }

        /// Canonical colon-separated display form (`"E8:C9:8F:52:7B:07"`).
        public var displayString: String {
            bytesLSBFirst.reversed()
                .map { String(format: "%02X", $0) }
                .joined(separator: ":")
        }
    }

    /// Add one MAC address to the board's whitelist table.
    ///
    /// `index` must be in `1…8` and entries must be written in increasing order
    /// starting at 1 (firmware constraint — the same as the C++ SDK).
    public struct AddWhitelistAddress: MWCommand, Sendable {
        public let index: UInt8
        public let address: BluetoothAddress

        public init(index: UInt8, address: BluetoothAddress) {
            self.index   = index
            self.address = address
        }

        public var commandData: Data {
            MWPacket.command(.settings, 0x14,
                [index, address.type.rawValue] + address.bytesLSBFirst
            )
        }
    }

    // MARK: - 3V regulator (MMS only, settings revision ≥ 9)
    //
    // Register 0x1C (`THREE_VOLT_POWER`). Mirrors C++
    // `mbl_mw_settings_enable_3V_regulator`. Silently ignored by non-MMS boards.
    /// Enable or disable the 3.3 V regulator on MetaMotion S.
    /// No-op on non-MMS boards. Requires settings module revision ≥ 9.
    public struct SetThreeVoltPower: MWCommand, Sendable {
        public let enabled: Bool

        public init(_ enabled: Bool) { self.enabled = enabled }

        public var commandData: Data {
            MWPacket.command(.settings, 0x1C, [enabled ? 0x01 : 0x00])
        }
    }

    // MARK: - Force 1M PHY (MMS only, settings revision ≥ 10)
    //
    // Register 0x1D (`FORCE_1M_PHY`). Mirrors C++ `mbl_mw_settings_force_1M_phy`.
    // When enabled the board pins its PHY to 1 Mbps — useful for diagnosing
    // 2 M PHY interoperability issues on MetaMotion S. No-op on older firmware.
    /// Force the BLE radio to use the 1 Mbps PHY. Useful when debugging
    /// 2 M PHY interoperability on MetaMotion S. Requires settings module
    /// revision ≥ 10; no-op on older firmware.
    public struct SetForce1MPhy: MWCommand, Sendable {
        public let enabled: Bool

        public init(_ enabled: Bool) { self.enabled = enabled }

        public var commandData: Data {
            MWPacket.command(.settings, 0x1D, [enabled ? 0x01 : 0x00])
        }
    }
}

// MARK: - MetaWearDevice settings convenience

public extension MetaWearDevice {
    /// Write a scan-response payload to the board. Payloads ≤ 13 bytes emit a
    /// single write to `SCAN_RESPONSE` (0x07); longer payloads are split across
    /// `PARTIAL_SCAN_RESPONSE` (0x08) + `SCAN_RESPONSE` (0x07).
    func setScanResponse(_ payload: [UInt8]) async throws {
        for cmd in MWSettings.SetScanResponse(payload).commands {
            try await writeRaw(cmd)
        }
    }
}

// MARK: - Preset connection parameter profiles

public extension MWSettings.SetConnectionParameters {
    /// Low-latency profile: 7.5 ms interval, suitable for high-frequency streaming.
    static var lowLatency: MWSettings.SetConnectionParameters {
        MWSettings.SetConnectionParameters(minInterval: 6, maxInterval: 6, latency: 0, timeout: 200)
    }

    /// Balanced profile: 30 ms interval, good for most use cases.
    static var balanced: MWSettings.SetConnectionParameters {
        MWSettings.SetConnectionParameters(minInterval: 24, maxInterval: 24, latency: 0, timeout: 500)
    }

    /// Power-saving profile: longer interval, less frequent connection events.
    static var powerSaving: MWSettings.SetConnectionParameters {
        MWSettings.SetConnectionParameters(minInterval: 80, maxInterval: 100, latency: 4, timeout: 600)
    }
}
