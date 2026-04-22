import MetaWear

// MARK: - CartesianFloat

extension CartesianFloat: MWPersistable {
    public static var persistenceKind: String { "cartesian" }
    public var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) {
        (x, y, z, 0, 0)
    }
    public static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> CartesianFloat {
        CartesianFloat(x: f0, y: f1, z: f2)
    }
}

// MARK: - Quaternion

extension Quaternion: MWPersistable {
    public static var persistenceKind: String { "quaternion" }
    public var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) {
        (w, x, y, z, 0)
    }
    public static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> Quaternion {
        Quaternion(w: f0, x: f1, y: f2, z: f3)
    }
}

// MARK: - EulerAngles

extension EulerAngles: MWPersistable {
    public static var persistenceKind: String { "euler" }
    public var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) {
        (heading, pitch, roll, yaw, 0)
    }
    public static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> EulerAngles {
        EulerAngles(heading: f0, pitch: f1, roll: f2, yaw: f3)
    }
}

// MARK: - CorrectedCartesianFloat

extension CorrectedCartesianFloat: MWPersistable {
    public static var persistenceKind: String { "corrected-cartesian" }
    public var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) {
        (x, y, z, 0, accuracy)
    }
    public static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> CorrectedCartesianFloat {
        CorrectedCartesianFloat(x: f0, y: f1, z: f2, accuracy: accuracy)
    }
}

// MARK: - Float

extension Float: MWPersistable {
    public static var persistenceKind: String { "float" }
    public var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) {
        (self, 0, 0, 0, 0)
    }
    public static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> Float {
        f0
    }
}

// MARK: - Bool

extension Bool: MWPersistable {
    public static var persistenceKind: String { "bool" }
    public var persistenceValues: (f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) {
        (self ? 1 : 0, 0, 0, 0, 0)
    }
    public static func from(f0: Float, f1: Float, f2: Float, f3: Float, accuracy: UInt8) -> Bool {
        f0 != 0
    }
}
