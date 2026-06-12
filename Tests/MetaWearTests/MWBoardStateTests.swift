import Testing
import Foundation
@preconcurrency import CoreBluetooth
@testable import MetaWear

// MARK: - Board state serialization
//
// Mirrors MetaWear-SDK-Cpp/test/test_metawearboard.py:
//   TestMetaWearBoard.test_module_info       — module.extra byte preservation
//   TestMetaWearBoardInitialize.test_reinitialize  — discovery-command set coverage
//   TestMetaWearBoardSerialize.test_serialize_motion_r (and deserialize)
//                                            — round-trip of post-init board state
//
// The binary blob format is intentionally NOT ported: it's tied to C++ struct
// layout and never was a stable on-disk format. Instead we verify a Swift-
// native Codable round-trip, which is what the Swift SDK exposes.

@Suite("MWModuleInfo — extra bytes")
struct MWModuleInfoExtraBytesTests {

    // Default extra is empty and isPresent is based on implementation != 0xFF.
    @Test func defaultExtra_isEmpty() {
        let info = MWModuleInfo(module: .switch_, implementation: 0, revision: 0)
        #expect(info.extra == [])
        #expect(info.isPresent == true)
    }

    @Test func implementationFF_isAbsent() {
        let info = MWModuleInfo(module: .humidity, implementation: 0xFF, revision: 0xFF)
        #expect(info.isPresent == false)
    }

    // Python test_module_info reference vectors for a MotionR board:
    //   DataProcessor: extra=[0x1c], revision=0
    //   Event:         extra=[0x1c], revision=0
    //   Logging:       extra=[0x08, 0x80, 0x2b, 0x00, 0x00], revision=2
    //   SensorFusion:  extra=[0x03, 0x00, 0x06, 0x00, 0x02, 0x00, 0x01, 0x00]
    @Test func knownExtraBytes_motionR() {
        let logging = MWModuleInfo(
            module: .logging,
            implementation: 0,
            revision: 2,
            extra: [0x08, 0x80, 0x2B, 0x00, 0x00]
        )
        #expect(logging.extra == [0x08, 0x80, 0x2B, 0x00, 0x00])
        #expect(logging.revision == 2)

        let fusion = MWModuleInfo(
            module: .sensorFusion,
            implementation: 0,
            revision: 0,
            extra: [0x03, 0x00, 0x06, 0x00, 0x02, 0x00, 0x01, 0x00]
        )
        #expect(fusion.extra.count == 8)
    }

    @Test func codable_roundTrip_preservesExtra() throws {
        let original = MWModuleInfo(
            module: .dataProcessor,
            implementation: 0,
            revision: 0,
            extra: [0x1C]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MWModuleInfo.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Protocol-layer module discovery

@Suite("MWProtocolLayer — module discovery extra bytes")
struct MWProtocolLayerModuleInfoTests {

    /// Stand in for each Python test_module_info case: inject a full response
    /// `[module, 0x80, impl, rev, extra...]` and confirm `MWModuleInfo` captures
    /// every byte.
    @Test func discoverModules_capturesExtraBytes() async throws {
        let transport = MockBLETransport()
        let proto = MWProtocolLayer(transport: transport)
        try await proto.start()

        // Inject a discovery reply for every known module.
        let injector = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)
            // Sparse — just the modules whose extra bytes we want to verify.
            // Everything else falls through to a minimal [module, 0x80, 0xFF, 0xFF].
            let scripted: [UInt8: [UInt8]] = [
                0x09: [0x09, 0x80, 0x00, 0x00, 0x1C],  // DataProcessor extra=[0x1C]
                0x0B: [0x0B, 0x80, 0x00, 0x02, 0x08, 0x80, 0x2B, 0x00, 0x00], // Logging
                0x19: [0x19, 0x80, 0x00, 0x00, 0x03, 0x00, 0x06, 0x00, 0x02, 0x00, 0x01, 0x00], // Fusion
            ]
            for module in MWModule.allCases {
                let response = scripted[module.rawValue] ?? [module.rawValue, 0x80, 0xFF, 0xFF]
                await transport.inject(notification: Data(response), to: MWUUIDs.notify)
            }
        }
        defer { injector.cancel() }

        let modules = try await proto.discoverModules()

        #expect(modules[.dataProcessor]?.extra == [0x1C])
        #expect(modules[.logging]?.extra == [0x08, 0x80, 0x2B, 0x00, 0x00])
        #expect(modules[.logging]?.revision == 2)
        #expect(modules[.sensorFusion]?.extra.count == 8)
        #expect(modules[.humidity]?.isPresent == false)   // 0xFF response
    }
}

// MARK: - MWBoardState round-trip

@Suite("MWBoardState — Codable round-trip")
struct MWBoardStateCodableTests {

    private func makeSampleState() -> MWBoardState {
        let info = MWDeviceInformation(
            manufacturer: "MbientLab",
            modelNumber: "8",                  // MetaMotion S
            serialNumber: "CAFEBABE",
            firmwareRevision: "1.5.0",
            hardwareRevision: "r0.1"
        )
        let modules: [MWModuleInfo] = [
            MWModuleInfo(module: .switch_, implementation: 0, revision: 0),
            MWModuleInfo(module: .accelerometer, implementation: 1, revision: 1),
            MWModuleInfo(module: .logging, implementation: 0, revision: 2,
                         extra: [0x08, 0x80, 0x2B, 0x00, 0x00]),
            MWModuleInfo(module: .sensorFusion, implementation: 0, revision: 0,
                         extra: [0x03, 0x00, 0x06, 0x00, 0x02, 0x00, 0x01, 0x00]),
            MWModuleInfo(module: .humidity, implementation: 0xFF, revision: 0xFF),
        ]
        return MWBoardState(
            deviceInformation: info,
            modules: modules,
            logReferenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func encode_decode_preservesAllFields() throws {
        let original = makeSampleState()
        let data = try original.encode()
        let decoded = try MWBoardState.decode(data)
        #expect(decoded == original)
    }

    @Test func encode_producesDeterministicJSON() throws {
        let state = makeSampleState()
        let a = try state.encode()
        let b = try state.encode()
        #expect(a == b)
    }

    @Test func schemaVersion_isCurrent() throws {
        let state = makeSampleState()
        let data = try state.encode()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == MWBoardState.currentSchemaVersion)
    }

    @Test func decode_rejectsFutureSchemaVersion() throws {
        // Hand-craft a JSON doc with schemaVersion = currentVersion + 1.
        let future = MWBoardState.currentSchemaVersion + 1
        let json: [String: Any] = [
            "schemaVersion": future,
            "deviceInformation": [
                "manufacturer": "x", "modelNumber": "x", "serialNumber": "x",
                "firmwareRevision": "x", "hardwareRevision": "x"
            ],
            "modules": [],
            // logReferenceDate omitted (nil)
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: MWError.self) { _ = try MWBoardState.decode(data) }
    }

    @Test func decode_garbageData_throws() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(throws: MWError.self) { _ = try MWBoardState.decode(garbage) }
    }

    // MARK: Compatibility check

    @Test func isCompatible_samefirmware_returnsTrue() {
        let state = makeSampleState()
        #expect(state.isCompatible(with: state.deviceInformation) == true)
    }

    @Test func isCompatible_differentFirmware_returnsFalse() {
        let state = makeSampleState()
        let newer = MWDeviceInformation(
            manufacturer: state.deviceInformation.manufacturer,
            modelNumber:  state.deviceInformation.modelNumber,
            serialNumber: state.deviceInformation.serialNumber,
            firmwareRevision: "1.6.0",   // bumped
            hardwareRevision: state.deviceInformation.hardwareRevision
        )
        #expect(state.isCompatible(with: newer) == false)
    }

    @Test func isCompatible_differentHardware_returnsFalse() {
        let state = makeSampleState()
        let swapped = MWDeviceInformation(
            manufacturer: state.deviceInformation.manufacturer,
            modelNumber: state.deviceInformation.modelNumber,
            serialNumber: state.deviceInformation.serialNumber,
            firmwareRevision: state.deviceInformation.firmwareRevision,
            hardwareRevision: "0.5"
        )
        #expect(state.isCompatible(with: swapped) == false)
    }

    @Test func modulesByOpcode_providesLookup() {
        let state = makeSampleState()
        #expect(state.modulesByOpcode[.logging]?.revision == 2)
        #expect(state.modulesByOpcode[.humidity]?.isPresent == false)
        #expect(state.modulesByOpcode[.gyro] == nil)  // not included in sample
    }
}

// MARK: - MetaWearDevice capture / restore

@Suite("MetaWearDevice — state capture + restore")
struct MetaWearDeviceStateCaptureTests {

    private func makeInfo() -> MWDeviceInformation {
        MWDeviceInformation(
            manufacturer: "MbientLab",
            modelNumber: "8",                  // MetaMotion S
            serialNumber: "A0B1",
            firmwareRevision: "1.5.0",
            hardwareRevision: "r0.1"
        )
    }

    private func makeModules() -> [MWModuleInfo] {
        [
            MWModuleInfo(module: .switch_, implementation: 0, revision: 0),
            MWModuleInfo(module: .accelerometer, implementation: 1, revision: 1),
            MWModuleInfo(module: .logging, implementation: 0, revision: 2,
                         extra: [0x08, 0x80, 0x2B, 0x00, 0x00]),
        ]
    }

    @Test func captureBoardState_beforeConnect_returnsNil() async {
        let device = MetaWearDevice(identifier: UUID(), transport: MockBLETransport())
        let snapshot = await device.captureBoardState()
        #expect(snapshot == nil)
    }

    @Test func restoreBoardState_populatesFields() async throws {
        let device = MetaWearDevice(identifier: UUID(), transport: MockBLETransport())
        let state = MWBoardState(
            deviceInformation: makeInfo(),
            modules: makeModules(),
            logReferenceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await device.restoreBoardState(state)

        let info = await device.deviceInfo
        let modules = await device.modules
        #expect(info == makeInfo())
        #expect(modules[.logging]?.extra == [0x08, 0x80, 0x2B, 0x00, 0x00])
        #expect(modules[.accelerometer]?.revision == 1)
    }

    @Test func captureAfterRestore_roundTripsState() async throws {
        let device = MetaWearDevice(identifier: UUID(), transport: MockBLETransport())
        let state = MWBoardState(
            deviceInformation: makeInfo(),
            modules: makeModules(),
            logReferenceDate: nil
        )
        try await device.restoreBoardState(state)
        let captured = await device.captureBoardState()
        #expect(captured?.deviceInformation == state.deviceInformation)
        #expect(captured?.modulesByOpcode[.logging]?.extra == [0x08, 0x80, 0x2B, 0x00, 0x00])
        #expect(captured?.logReferenceDate == nil)
    }
}
