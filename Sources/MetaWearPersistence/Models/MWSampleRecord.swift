import SwiftData
import Foundation

/// One persisted sensor sample.
///
/// All sensor value types are stored as up to four `Float` fields plus an
/// optional `accuracy` byte. This flat layout means a single entity handles
/// CartesianFloat, Quaternion, EulerAngles, CorrectedCartesianFloat, Float, and Bool
/// without branching in the persistence layer.
///
/// Field mapping by sensor kind:
/// ```
/// CartesianFloat          f0=x  f1=y  f2=z  f3=0   accuracy=0
/// Quaternion              f0=w  f1=x  f2=y  f3=z   accuracy=0
/// EulerAngles             f0=heading f1=pitch f2=roll f3=yaw  accuracy=0
/// CorrectedCartesianFloat f0=x  f1=y  f2=z  f3=0   accuracy=<value>
/// Float                   f0=v  f1=0  f2=0  f3=0   accuracy=0
/// Bool                    f0=1|0 f1=0 f2=0  f3=0   accuracy=0
/// ```
@Model
public final class MWSampleRecord {

    public var session: MWSessionRecord?

    /// Wall-clock timestamp.
    public var date: Date
    /// Elapsed milliseconds since the MetaWear last reset.
    public var tickMs: Double

    /// Primary value component.
    public var f0: Float
    public var f1: Float
    public var f2: Float
    public var f3: Float
    /// CorrectedCartesianFloat accuracy (0 for all other types).
    public var accuracy: UInt8

    public init(
        date: Date,
        tickMs: Double,
        f0: Float, f1: Float, f2: Float, f3: Float,
        accuracy: UInt8 = 0
    ) {
        self.date     = date
        self.tickMs   = tickMs
        self.f0       = f0
        self.f1       = f1
        self.f2       = f2
        self.f3       = f3
        self.accuracy = accuracy
    }
}
