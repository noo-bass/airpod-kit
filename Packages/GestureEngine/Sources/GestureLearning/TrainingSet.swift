import Foundation
import GestureEngine

/// What an approach learns from: takes of each gesture, and ordinary use.
public struct TrainingSet {
    public var gestures: [String]
    public var takes: [String: [Recording]]
    public var background: [[MotionSample]]
    public var readingsPerSecond: Double

    public init(gestures: [String], takes: [String: [Recording]], background: [[MotionSample]], readingsPerSecond: Double) {
        self.gestures = gestures
        self.takes = takes
        self.background = background
        self.readingsPerSecond = readingsPerSecond
    }

    /// Everything recorded, for training the live test. Gestures with fewer
    /// than `minimumTakes` are left out.
    public init(recordings: [Recording], minimumTakes: Int) {
        let takesByLabel = Dictionary(grouping: recordings.filter { $0.kind == .take }, by: \.label)
            .filter { $0.value.count >= minimumTakes }
        let intervals = recordings.flatMap { recording in
            zip(recording.samples.dropFirst(), recording.samples).map { $0.timestamp - $1.timestamp }
        }.filter { $0 > 0 }.sorted()
        self.init(
            gestures: takesByLabel.keys.sorted(),
            takes: takesByLabel,
            background: recordings.filter { $0.kind == .background }.map(\.samples),
            readingsPerSecond: intervals.isEmpty ? 50 : 1 / intervals[intervals.count / 2]
        )
    }
}

/// Repeatable shuffles, so the same recordings always give the same split
/// and two runs can be compared.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
