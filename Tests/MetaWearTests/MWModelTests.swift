import Testing
@testable import MetaWear

@Suite("MWModel")
struct MWModelTests {

    // MARK: - Model number → case
    //
    // Per `MetaWear-SDK-Cpp/src/metawear/impl/cpp/metawearboard.cpp` the firmware
    // reports model "5" for MetaMotion R / RL and "8" for MetaMotion S in the
    // Model Number BLE characteristic (0x2A24). All other values map to
    // `.unknown` — this SDK only supports MMR/RL and MMS.

    @Test func motionRL_isModelNumber5() { #expect(MWModel(modelNumber: "5") == .motionRL) }
    @Test func motionS_isModelNumber8()  { #expect(MWModel(modelNumber: "8") == .motionS) }

    @Test func unknownNumber_isUnknown()  {
        if case .unknown = MWModel(modelNumber: "99") { } else { Issue.record("Expected .unknown") }
    }
    @Test func emptyString_isUnknown() {
        if case .unknown = MWModel(modelNumber: "") { } else { Issue.record("Expected .unknown") }
    }
    @Test func whitespace_isTrimmed() { #expect(MWModel(modelNumber: " 8 ") == .motionS) }

    // Boards we deliberately don't claim support for — make sure they don't
    // silently get classified as something else.
    @Test func metawearC_modelNumber2_isUnknown() {
        if case .unknown = MWModel(modelNumber: "2") { } else { Issue.record("Model 2 should be .unknown") }
    }
    @Test func metaMotionC_modelNumber6_isUnknown() {
        if case .unknown = MWModel(modelNumber: "6") { } else { Issue.record("Model 6 should be .unknown") }
    }

    // MARK: - Display name

    @Test func motionRL_name() { #expect(MWModel.motionRL.name == "MetaMotion R / RL") }
    @Test func motionS_name()  { #expect(MWModel.motionS.name  == "MetaMotion S") }
    @Test func unknown_nameContainsNumber() {
        #expect(MWModel(modelNumber: "7").name.contains("7"))
    }

    // MARK: - Capability

    @Test func motionS_hasMMS()  { #expect(MWModel.motionS.hasMMS  == true) }
    @Test func motionRL_noMMS()  { #expect(MWModel.motionRL.hasMMS == false) }

    // MARK: - Hardware revisions

    @Test func motionRL_supportedHardwareRevisions() {
        #expect(MWModel.motionRL.supportedHardwareRevisions ==
                ["r0.1", "r0.2", "r0.3", "r0.4", "r0.5"])
    }

    @Test func motionS_supportedHardwareRevisions() {
        #expect(MWModel.motionS.supportedHardwareRevisions == ["r0.1"])
    }

    @Test func unknown_supportedHardwareRevisions_isEmpty() {
        #expect(MWModel(modelNumber: "7").supportedHardwareRevisions.isEmpty)
    }

    @Test func motionRL_acceptsAllShippedRevisions() {
        for r in ["r0.1", "r0.2", "r0.3", "r0.4", "r0.5"] {
            #expect(MWModel.motionRL.isHardwareRevisionSupported(r),
                    "Expected \(r) to be supported on MMR/RL")
        }
    }

    @Test func motionRL_rejectsUnknownRevision() {
        #expect(MWModel.motionRL.isHardwareRevisionSupported("r0.6") == false)
        #expect(MWModel.motionRL.isHardwareRevisionSupported("r1.0") == false)
    }

    @Test func motionS_acceptsR01() {
        #expect(MWModel.motionS.isHardwareRevisionSupported("r0.1") == true)
    }

    @Test func motionS_rejectsAnythingElse() {
        #expect(MWModel.motionS.isHardwareRevisionSupported("r0.2") == false)
        #expect(MWModel.motionS.isHardwareRevisionSupported("r0.5") == false)
    }

    /// Some firmware reports the bare `0.X` form without the leading `r`. The
    /// validator should accept either spelling so callers don't have to
    /// normalise themselves.
    @Test func validator_normalizesLeadingR() {
        #expect(MWModel.motionRL.isHardwareRevisionSupported("0.4") == true)
        #expect(MWModel.motionRL.isHardwareRevisionSupported("R0.4") == true)
        #expect(MWModel.motionRL.isHardwareRevisionSupported(" r0.4 ") == true)
    }

    // MARK: - MWDeviceInformation convenience

    @Test func deviceInfo_motionS() {
        let info = MWDeviceInformation(manufacturer: "MbientLab Inc.", modelNumber: "8",
                                       serialNumber: "AA:BB", firmwareRevision: "1.7.0",
                                       hardwareRevision: "r0.1")
        #expect(info.model == .motionS)
        #expect(info.isHardwareRevisionSupported)
    }

    @Test func deviceInfo_motionRL() {
        let info = MWDeviceInformation(manufacturer: "MbientLab Inc.", modelNumber: "5",
                                       serialNumber: "AA:BB", firmwareRevision: "1.7.0",
                                       hardwareRevision: "r0.4")
        #expect(info.model == .motionRL)
        #expect(info.isHardwareRevisionSupported)
    }

    @Test func deviceInfo_unsupportedRevision_failsValidation() {
        let info = MWDeviceInformation(manufacturer: "MbientLab Inc.", modelNumber: "8",
                                       serialNumber: "AA:BB", firmwareRevision: "1.7.0",
                                       hardwareRevision: "r0.9")
        #expect(info.model == .motionS)
        #expect(info.isHardwareRevisionSupported == false)
    }

    @Test func deviceInfo_unknownModel_failsRevisionValidation() {
        let info = MWDeviceInformation(manufacturer: "MbientLab Inc.", modelNumber: "99",
                                       serialNumber: "AA:BB", firmwareRevision: "1.7.0",
                                       hardwareRevision: "r0.1")
        if case .unknown = info.model { } else { Issue.record("Expected .unknown for model 99") }
        #expect(info.isHardwareRevisionSupported == false)
    }
}
