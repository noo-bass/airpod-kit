import Foundation

/// Three numbers along the AirPods' own axes.
public struct Vector3: Sendable, Codable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)
}

/// One reading from the AirPods' motion sensors: 50 a second from AirPods
/// Pro 2 (measured), 25 from some older models.
public struct MotionSample: Sendable, Codable, Equatable {
    /// Seconds, on whatever clock the source uses. Only differences matter.
    public var timestamp: TimeInterval
    /// Which way the head is pointing, in radians: pitch (nodding axis),
    /// roll (ear-to-shoulder axis), yaw (shaking axis).
    public var attitude: Vector3
    /// How fast the head is turning about each axis, in radians per second.
    public var rotationRate: Vector3
    /// Jolts with gravity taken out, in multiples of g. A jaw clench lives
    /// here: it is a tiny, sharp nudge to the earbud, not a turn of the head.
    public var userAcceleration: Vector3

    public init(timestamp: TimeInterval, attitude: Vector3, rotationRate: Vector3, userAcceleration: Vector3) {
        self.timestamp = timestamp
        self.attitude = attitude
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
    }

    /// The six numbers gestures are matched on.
    ///
    /// Attitude is left out on purpose. It says where the head is, not how it
    /// moved, so a nod learnt while facing the screen would fail to match a
    /// nod made while looking down at a notebook. Turning speed and jolts
    /// describe the movement itself, wherever it starts from.
    var features: [Double] {
        [rotationRate.x, rotationRate.y, rotationRate.z,
         userAcceleration.x, userAcceleration.y, userAcceleration.z]
    }

    static let featureCount = 6
}
