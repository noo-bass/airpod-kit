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
    /// Examples (counting from 1) left out because no movement was found in
    /// them, so the app can say which to re-record.
    public internal(set) var skippedExampleNumbers: [Int] = []

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

    /// How far the movement that just finished is from this gesture.
    /// Infinity when the movement is too weak to count; nil when there is not
    /// yet enough history to judge.
    public func distance(endingWith history: [MotionSample]) -> Double? {
        // A bit more history than the longest example, so a repeat done
        // slower than any example still fits inside the window.
        let windowLength = min(history.count, Int(Double(longestTemplateLength) * 1.5) + 2)
        guard windowLength >= 3 else { return nil }
        let window = history.suffix(windowLength).map { scaled($0.features) }
        let strongestMovement = window.map(GestureLearner.activityLevel).max() ?? 0
        return strongestMovement >= minimumActivity ? distance(to: window) : .infinity
    }

    /// Where the movement is in a recording, judged with this gesture's
    /// scaling. Used to find the gesture inside a take for other learners.
    public func movementRange(in samples: [MotionSample]) -> ClosedRange<Int>? {
        GestureLearner.movementBounds(samples.map { scaled($0.features) })?.range
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
        // noise".
        //
        // Resting jitter is measured on the quietest stretches only. The first
        // version took the spread of whole recordings, assuming they were
        // mostly stillness. Real nods were not: slow and broad, with the head
        // still settling from the previous take, they filled most of the
        // recording. Jitter came out at 0.56 rad/s, about twenty times too
        // high, and gentler nods vanished below it.
        let chunkLength = 12
        let quietChunks = recordings.flatMap { recording in
            Swift.stride(from: 0, to: recording.count - chunkLength + 1, by: chunkLength).map {
                recording[$0..<($0 + chunkLength)].map(\.features)
            }
        }
        var centre = [Double](repeating: 0, count: MotionSample.featureCount)
        var scale = [Double](repeating: 1, count: MotionSample.featureCount)
        for channel in 0..<MotionSample.featureCount {
            let middle = median(allFrames.map { $0[channel] })
            let chunkSpreads = quietChunks.map { chunk in
                let values = chunk.map { $0[channel] }
                let mean = values.reduce(0, +) / Double(values.count)
                return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            }.sorted()
            // The quietest quarter, so up to three quarters of the recordings
            // can be movement without spoiling the estimate.
            let spread = chunkSpreads.isEmpty ? 0 : chunkSpreads[chunkSpreads.count / 4]
            centre[channel] = middle
            // A tiny floor only, so a channel that read perfectly flat is not
            // divided by zero. The first floors (0.02 rad/s, 0.004 g) were
            // guesses made for made-up data, and real AirPods Pro measured
            // two to two and a half times quieter than that on three of six
            // channels. The floor then shrank real signal and faint jaw
            // clenches were rejected as no movement.
            scale[channel] = max(spread, channel < 3 ? 0.002 : 0.0003)
        }

        let partialModel = GestureModel(
            templates: [], channelScale: scale, channelCentre: centre,
            matchThreshold: 0, minimumActivity: 0, longestTemplateLength: 0
        )

        // A take where the gesture did not register is left out rather than
        // stopping the whole gesture: one fumbled clench in twenty should cost
        // that one take, not every approach that learns from the other
        // nineteen.
        var templates: [[[Double]]] = []
        var peakActivities: [Double] = []
        var skipped: [Int] = []
        for (index, recording) in recordings.enumerated() {
            let scaledFrames = recording.map { partialModel.scaled($0.features) }
            guard let trimmed = trimToMovement(scaledFrames) else {
                skipped.append(index + 1)
                continue
            }
            templates.append(trimmed.frames)
            peakActivities.append(trimmed.peakActivity)
        }
        if templates.count < minimumExamples, let firstSkipped = skipped.first {
            throw GestureLearningError.noMovementFound(exampleNumber: firstSkipped)
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
            longestTemplateLength: templates.map(\.count).max() ?? 0,
            skippedExampleNumbers: skipped
        )
    }

    /// Finds the part of a recording where something happened, and cuts away
    /// the stillness before and after. The stillness would otherwise become
    /// part of the "shape" and every live match would have to include it.
    static func trimToMovement(_ frames: [[Double]]) -> (frames: [[Double]], peakActivity: Double)? {
        guard let bounds = movementBounds(frames) else { return nil }
        return (Array(frames[bounds.range]), bounds.peak)
    }

    static func movementBounds(_ frames: [[Double]]) -> (range: ClosedRange<Int>, peak: Double)? {
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
        return (max(0, first - 2)...min(frames.count - 1, last + 2), peak)
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
