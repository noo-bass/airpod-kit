import Foundation

/// Watches the live stream of readings and says when a learnt gesture happens.
///
/// Generic over the key so the app can use its own gesture ids, and tests can
/// use plain strings.
public struct GestureDetector<GestureKey: Hashable & Sendable>: Sendable {
    public struct Watched: Sendable {
        public var model: GestureModel
        /// 1 is "as learnt". Above 1 accepts sloppier repeats (more false
        /// triggers); below 1 needs a closer copy (more misses).
        public var sensitivity: Double

        public init(model: GestureModel, sensitivity: Double = 1) {
            self.model = model
            self.sensitivity = sensitivity
        }

        var threshold: Double { model.matchThreshold * sensitivity }
    }

    /// How close each gesture currently is to firing, from 0 (nothing like it)
    /// to 1 (at the threshold). For the live meters in the window.
    public private(set) var closeness: [GestureKey: Double] = [:]

    private var watched: [GestureKey: Watched] = [:]
    private var history: [MotionSample] = []
    private var previousDistance: [GestureKey: Double] = [:]
    private var quietUntil: [GestureKey: TimeInterval] = [:]

    /// Longer than any sensible gesture. Measured in seconds, not readings,
    /// because the rate depends on the model: AirPods Pro 2 send 50 a second,
    /// older ones 25.
    private let historySeconds: TimeInterval = 5

    public init() {}

    public mutating func setWatched(_ gestures: [GestureKey: Watched]) {
        watched = gestures
        for key in previousDistance.keys where gestures[key] == nil {
            previousDistance[key] = nil
            closeness[key] = nil
            quietUntil[key] = nil
        }
    }

    /// Forgets recent movement. Call after a gap in the stream (AirPods taken
    /// out, recording an example), so a match is never stitched together from
    /// movement on either side of the gap.
    public mutating func reset() {
        history.removeAll()
        previousDistance.removeAll()
        closeness.removeAll()
    }

    /// Feeds one reading in and returns the gestures that just finished.
    public mutating func process(_ sample: MotionSample) -> [GestureKey] {
        history.append(sample)
        if let firstKept = history.firstIndex(where: { sample.timestamp - $0.timestamp <= historySeconds }), firstKept > 0 {
            history.removeFirst(firstKept)
        }

        // Templates are counted in readings, so the quiet period after a fire
        // needs the reading rate to turn that into seconds.
        let readingsPerSecond = history.count > 1
            ? Double(history.count - 1) / max(history.last!.timestamp - history.first!.timestamp, 0.001)
            : 25

        var fired: [GestureKey] = []
        for (key, gesture) in watched {
            let model = gesture.model
            if let quietEnd = quietUntil[key], sample.timestamp < quietEnd {
                closeness[key] = 0
                continue
            }
            // A bit more history than the longest example, so a repeat done
            // slower than any example still fits inside the window.
            let windowLength = min(history.count, Int(Double(model.longestTemplateLength) * 1.5) + 2)
            guard windowLength >= 3 else { continue }
            let window = history.suffix(windowLength).map { model.scaled($0.features) }

            let strongestMovement = window.map(GestureLearner.activityLevel).max() ?? 0
            let distance = strongestMovement >= model.minimumActivity
                ? model.distance(to: window)
                : .infinity
            closeness[key] = distance.isFinite ? min(1, gesture.threshold / distance) : 0

            // Fire at the best moment, not the first good-enough one. As a
            // gesture finishes, the distance keeps falling until the window
            // holds all of it, then rises again. Firing as soon as it crosses
            // the threshold would trigger on the first two-thirds of a nod and
            // then possibly again on the full nod. So wait for the turn: the
            // previous reading was under the threshold and this one is worse.
            let previous = previousDistance[key] ?? .infinity
            if previous < gesture.threshold, distance > previous {
                fired.append(key)
                // Stay quiet for about the length of the gesture, so the tail
                // of the same movement cannot match a second time.
                quietUntil[key] = sample.timestamp + max(0.4, Double(model.longestTemplateLength) / readingsPerSecond)
                previousDistance[key] = .infinity
                closeness[key] = 0
            } else {
                previousDistance[key] = distance
            }
        }
        return fired
    }
}
