import Testing
@testable import MetaWear

@Suite("MWModel")
struct MWModelTests {

    @Test func motionRL_isModelNumber10() { #expect(MWModel(modelNumber: "10") == .motionRL) }
    @Test func motionS_isModelNumber12()  { #expect(MWModel(modelNumber: "12") == .motionS) }

    @Test func unknownNumber_isUnknown()  {
        if case .unknown = MWModel(modelNumber: "99") { } else { Issue.record("Expected .unknown") }
    }
    @Test func emptyString_isUnknown() {
        if case .unknown = MWModel(modelNumber: "") { } else { Issue.record("Expected .unknown") }
    }
    @Test func whitespace_isTrimmed() { #expect(MWModel(modelNumber: " 12 ") == .motionS) }

    @Test func motionRL_name() { #expect(MWModel.motionRL.name == "MetaMotion RL") }
    @Test func motionS_name()  { #expect(MWModel.motionS.name  == "MetaMotion S") }
    @Test func unknown_nameContainsNumber() {
        #expect(MWModel(modelNumber: "7").name.contains("7"))
    }

    @Test func motionS_hasMMS()  { #expect(MWModel.motionS.hasMMS  == true) }
    @Test func motionRL_noMMS()  { #expect(MWModel.motionRL.hasMMS == false) }

    @Test func deviceInfo_motionS() {
        let info = MWDeviceInformation(manufacturer: "MbientLab Inc.", modelNumber: "12",
                                       serialNumber: "AA:BB", firmwareRevision: "1.7.0",
                                       hardwareRevision: "0.4")
        #expect(info.model == .motionS)
    }

    @Test func deviceInfo_motionRL() {
        let info = MWDeviceInformation(manufacturer: "MbientLab Inc.", modelNumber: "10",
                                       serialNumber: "AA:BB", firmwareRevision: "1.7.0",
                                       hardwareRevision: "0.4")
        #expect(info.model == .motionRL)
    }
}
