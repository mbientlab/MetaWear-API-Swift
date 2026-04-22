import Testing
import Foundation
@testable import MetaWear
@testable import MetaWearPersistence

// MARK: - Encode/decode round-trip tests for MWPersistable conformances
//
// These tests verify that persistenceKind, persistenceValues, and from(…)
// are consistent for every conforming type — no SwiftData or hardware needed.

@Suite("MWPersistable — kind strings")
struct MWPersistableKindTests {

    @Test func cartesian_persistenceKind() {
        #expect(CartesianFloat.persistenceKind == "cartesian")
    }

    @Test func quaternion_persistenceKind() {
        #expect(Quaternion.persistenceKind == "quaternion")
    }

    @Test func eulerAngles_persistenceKind() {
        #expect(EulerAngles.persistenceKind == "euler")
    }

    @Test func correctedCartesian_persistenceKind() {
        #expect(CorrectedCartesianFloat.persistenceKind == "corrected-cartesian")
    }

    @Test func float_persistenceKind() {
        #expect(Float.persistenceKind == "float")
    }

    @Test func bool_persistenceKind() {
        #expect(Bool.persistenceKind == "bool")
    }
}

@Suite("MWPersistable — encode/decode round-trip")
struct MWPersistableRoundTripTests {

    @Test func cartesian_roundTrip() {
        let original = CartesianFloat(x: 1.5, y: -0.25, z: 9.81)
        let v = original.persistenceValues
        let decoded = CartesianFloat.from(f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(abs(decoded.x - original.x) < 1e-5)
        #expect(abs(decoded.y - original.y) < 1e-5)
        #expect(abs(decoded.z - original.z) < 1e-5)
    }

    @Test func cartesian_f3_isZero() {
        let v = CartesianFloat(x: 1, y: 2, z: 3).persistenceValues
        #expect(v.f3 == 0)
        #expect(v.accuracy == 0)
    }

    @Test func quaternion_roundTrip() {
        let original = Quaternion(w: 0.707, x: 0.0, y: 0.707, z: 0.0)
        let v = original.persistenceValues
        let decoded = Quaternion.from(f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(abs(decoded.w - original.w) < 1e-5)
        #expect(abs(decoded.x - original.x) < 1e-5)
        #expect(abs(decoded.y - original.y) < 1e-5)
        #expect(abs(decoded.z - original.z) < 1e-5)
    }

    @Test func quaternion_mapping_wIsF0() {
        let q = Quaternion(w: 10, x: 20, y: 30, z: 40)
        let v = q.persistenceValues
        #expect(v.f0 == 10)  // w
        #expect(v.f1 == 20)  // x
        #expect(v.f2 == 30)  // y
        #expect(v.f3 == 40)  // z
    }

    @Test func eulerAngles_roundTrip() {
        let original = EulerAngles(heading: 45.0, pitch: -10.0, roll: 5.0, yaw: 90.0)
        let v = original.persistenceValues
        let decoded = EulerAngles.from(f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(abs(decoded.heading - original.heading) < 1e-5)
        #expect(abs(decoded.pitch   - original.pitch)   < 1e-5)
        #expect(abs(decoded.roll    - original.roll)    < 1e-5)
        #expect(abs(decoded.yaw     - original.yaw)     < 1e-5)
    }

    @Test func correctedCartesian_roundTrip_preservesAccuracy() {
        let original = CorrectedCartesianFloat(x: 0.1, y: 0.2, z: 0.3, accuracy: 3)
        let v = original.persistenceValues
        let decoded = CorrectedCartesianFloat.from(
            f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(abs(decoded.x - original.x) < 1e-5)
        #expect(abs(decoded.y - original.y) < 1e-5)
        #expect(abs(decoded.z - original.z) < 1e-5)
        #expect(decoded.accuracy == original.accuracy)
    }

    @Test func correctedCartesian_f3_isZero() {
        let v = CorrectedCartesianFloat(x: 1, y: 2, z: 3, accuracy: 2).persistenceValues
        #expect(v.f3 == 0)
    }

    @Test func float_roundTrip() {
        let original: Float = 3.14159
        let v = original.persistenceValues
        let decoded = Float.from(f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(abs(decoded - original) < 1e-5)
    }

    @Test func float_paddingIsZero() {
        let v: Float = 42.0
        let pv = v.persistenceValues
        #expect(pv.f1 == 0)
        #expect(pv.f2 == 0)
        #expect(pv.f3 == 0)
        #expect(pv.accuracy == 0)
    }

    @Test func bool_true_roundTrip() {
        let v = true.persistenceValues
        let decoded = Bool.from(f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(decoded == true)
        #expect(v.f0 == 1)
    }

    @Test func bool_false_roundTrip() {
        let v = false.persistenceValues
        let decoded = Bool.from(f0: v.f0, f1: v.f1, f2: v.f2, f3: v.f3, accuracy: v.accuracy)
        #expect(decoded == false)
        #expect(v.f0 == 0)
    }
}
