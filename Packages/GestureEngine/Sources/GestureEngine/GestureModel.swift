import Foundation

/// What the app has learnt about one gesture from the examples it was shown.
public struct GestureModel: Sendable, Codable, Equatable {
    /// Each example, cut down to just the movement and already scaled.
    var templates: [[[Double]]]
    /// Per-sensor-channel divisor, so each channel is measured in multiples of
    /// its own resting jitter. See `GestureLearner.learn` for why.
    var channelScale: [Double]
    /// Per-channel resting value, taken away before scaling. The earbuds are
    /// rarely perfectly still at zero, and a constant offset is not movement.
    var channelCentre: [Double]
    /// Distance under which the stream counts as this gesture, before the
    /// user's sensitivity setting is applied.
    public internal(set) var matchThreshold: Double
    /// The movement must be at least this strong (in scaled units) to count.
    /// Without this gate a still head can drift into matching a gentle
    /// gesture's shape purely from sensor noise.
    var minimumActivity: Double
    /// Longest example, in readings. Sets how much history to compare.
    var longestTemplateLength: Int

    public var exampleCount: Int { templates.count }

    /// How many multiples of resting jitter to ignore on each channel.
    ///
    /// Without this, two stretches of pure stillness differ by about 3.4
    /// units (six channels of independent jitter), while a jaw clench only
    /// peaks at about 10. Stillness then sits close enough to a faint
    /// gesture's shape that the detector fired on nothing. Shaving off the
    /// jitter makes stillness read as exactly zero, so only real movement
    /// carries any distance.
    static let jitterAllowance = 2.0

    func scaled(_ features: [Double]) -> [Double] {
        var result = features
        for index in result.indices {
            let inJitterUnits = (features[index] - channelCentre[index]) / channelScale[index]
            let beyondJitter = max(abs(inJitterUnits) - Self.jitterAllowance, 0)
            result[index] = inJitterUnits < 0 ? -beyondJitter : beyondJitter
        }
        return result
    }

    func distance(to scaledStream: [[Double]]) -> Double {
        templates.map { subsequenceDistance(template: $0, stream: scaledStream) }.min() ?? .infinity
    }
}

public enum GestureLearningError: Error, Equatable, LocalizedError {
    case needMoreExamples(have: Int, need: Int)
    case noMovementFound(exampleNumber: Int)

    public var errorDescription: String? {
        switch self {
        case let .needMoreExamples(have, need):
            "Record \(need - have) more example\(need - have == 1 ? "" : "s") so the app can tell what stays the same each time."
        case let .noMovementFound(exampleNumber):
            "Example \(exampleNumber) looks like no movement at all. Delete it and record it again, moving a little more clearly."
        }
    }
}

public enum GestureLearner {
    public static let minimumExamples = 2

    /// Builds a model from raw recordings, each holding one go at the gesture
    /// with some stillness around it.
    public static func learn(from recordings: [[MotionSample]]) throws -> GestureModel {
        guard recordings.count >= minimumExamples else {
            throw GestureLearningError.needMoreExamples(have: recordings.count, need: minimumExamples)
        }
        let allFrames = recordings.flatMap { $0.map(\.features) }

        // Scale each channel by how much it jitters at rest.
        //
        // Turning speed and jolts are in different units and wildly different
        // sizes: a nod turns the head at 2 rad/s, while a jaw clench nudges the
        // earbud by about 0.02 g. Compared raw, a clench would be invisible
        // next to the slightest head turn. Dividing each channel by its own
        // resting jitter puts them on one footing: "how many times bigger than
        // noise". The middle of each channel's spread is used for "at rest"
        // because most of each recording is stillness around a short movement.
        var centre = [Double](repeating: 0, count: MotionSample.featureCount)
        var scale = [Double](repeating: 1, count: MotionSample.featureCount)
        for channel in 0..<MotionSample.featureCount {
            let values = allFrames.map { $0[channel] }
            let middle = median(values)
            let spread = median(values.map { abs($0 - middle) }) * 1.4826
            centre[channel] = middle
            // A floor stops a channel that happened to read perfectly flat
            // from being divided by zero and then blowing up at the first
            // wobble of real use.
            scale[channel] = max(spread, channel < 3 ? 0.02 : 0.004)
        }

        let partialModel = GestureModel(
            templates: [], channelScale: scale, channelCentre: centre,
            matchThreshold: 0, minimumActivity: 0, longestTemplateLength: 0
        )

        var templates: [[[Double]]] = []
        var peakActivities: [Double] = []
        for (index, recording) in recordings.enumerated() {
            let scaledFrames = recording.map { partialModel.scaled($0.features) }
            guard let trimmed = trimToMovement(scaledFrames) else {
                throw GestureLearningError.noMovementFound(exampleNumber: index + 1)
            }
            templates.append(trimmed.frames)
            peakActivities.append(trimmed.peakActivity)
        }

        // The threshold comes from how much the examples differ from each
        // other. If five nods are all within distance 2 of their closest
        // sibling, a live movement within about that distance is a nod too.
        // The worst case is used, not the average, because the user showed
        // every example as a real nod; the margin covers the variation they
        // did not happen to record.
        var nearestSiblingDistances: [Double] = []
        for (index, template) in templates.enumerated() {
            let nearest = templates.enumerated()
                .filter { $0.offset != index }
                .map { subsequenceDistance(template: template, stream: $0.element) }
                .min() ?? .infinity
            nearestSiblingDistances.append(nearest)
        }
        // How far each example is from complete stillness. Any threshold at
        // or above this would accept stillness itself as the gesture.
        //
        // This matters most for small gestures. A jaw clench is a two-reading
        // bump with stillness either side, so averaged over its length it is
        // only about 1.6 away from nothing. A fixed slack of 1.5 let stillness,
        // and the instant mid-nod when the head stops turning, count as a
        // clench. So the slack is sized to the gesture: never more than half
        // its distance from stillness, and never less than a quarter of it,
        // which stops near-identical examples from demanding a perfect copy.
        let stillnessDistance = templates.map { template in
            template.map(activityLevel).reduce(0, +) / Double(template.count)
        }.min() ?? 0
        let fromExamples = (nearestSiblingDistances.max() ?? 0) * 1.3
        let threshold = min(max(fromExamples, stillnessDistance * 0.25), stillnessDistance * 0.5)

        return GestureModel(
            templates: templates,
            channelScale: scale,
            channelCentre: centre,
            matchThreshold: threshold,
            minimumActivity: (peakActivities.min() ?? 0) * 0.5,
            longestTemplateLength: templates.map(\.count).max() ?? 0
        )
    }

    /// Finds the part of a recording where something happened, and cuts away
    /// the stillness before and after. The stillness would otherwise become
    /// part of the "shape" and every live match would have to include it.
    static func trimToMovement(_ frames: [[Double]]) -> (frames: [[Double]], peakActivity: Double)? {
        let activity = frames.map(activityLevel)
        // Activity is measured after the jitter allowance is taken off, so 4
        // here is about six times resting jitter on the strongest channel.
        guard let peak = activity.max(), peak >= 4 else { return nil }
        // "Moving" is anything above a fifth of the peak, and never the
        // occasional lone blip that noise reaches past the allowance.
        let cutoff = max(1, peak * 0.2)
        guard let first = activity.firstIndex(where: { $0 >= cutoff }),
              let last = activity.lastIndex(where: { $0 >= cutoff }) else { return nil }
        // Two readings either side keep the gentle start and finish of the
        // movement, which help tell, say, a nod from a single downward dip.
        let start = max(0, first - 2)
        let end = min(frames.count - 1, last + 2)
        return (Array(frames[start...end]), peak)
    }

    static func activityLevel(_ scaledFrame: [Double]) -> Double {
        euclideanDistance(scaledFrame, [Double](repeating: 0, count: scaledFrame.count))
    }
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
