import Foundation

/// One inertial sample from a controller, already converted to physical units.
///
/// Angular rates are degrees per second and acceleration is in g, both in the controller's
/// own frame: `x` is the axis pointing right through the pad, `y` the axis pointing from the
/// bottom edge to the top edge, `z` the axis pointing out of the controller's face. Yaw is
/// rotation about `y`, pitch about `x`, and roll about `z`.
///
/// Only the raw gyroscope/accelerometer pair is modelled. The 2026 Steam Controller's full
/// state report also carries a quaternion, but Valve's firmware has already shipped a
/// regression that removed it and left the fused result drifting, so every consumer in this
/// space reads raw rates instead. Anything that needs gravity derives it here.
public struct ControllerMotionSample: Equatable, Sendable {
    public var gyroX: Float
    public var gyroY: Float
    public var gyroZ: Float
    public var accelX: Float
    public var accelY: Float
    public var accelZ: Float
    /// The report's own sensor tick, in microseconds, when the report carries one. Used only to
    /// detect a stalled IMU: the firmware repeats the previous value verbatim when motion
    /// reporting is off, so an unchanging tick is how a silent IMU is told apart from a still one.
    public var timestampMicroseconds: UInt32?

    public init(gyroX: Float = 0,
                gyroY: Float = 0,
                gyroZ: Float = 0,
                accelX: Float = 0,
                accelY: Float = 0,
                accelZ: Float = 0,
                timestampMicroseconds: UInt32? = nil) {
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.timestampMicroseconds = timestampMicroseconds
    }

    public static let zero = ControllerMotionSample()

    public var isZero: Bool { self == .zero }

    /// Magnitude of the angular rate vector, in degrees per second.
    public var gyroMagnitude: Float {
        (gyroX * gyroX + gyroY * gyroY + gyroZ * gyroZ).squareRoot()
    }

    /// Magnitude of the acceleration vector, in g. A pad at rest reads 1 g.
    public var accelMagnitude: Float {
        (accelX * accelX + accelY * accelY + accelZ * accelZ).squareRoot()
    }
}
