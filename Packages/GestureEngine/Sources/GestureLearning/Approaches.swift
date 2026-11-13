import CoreML
import CreateML
import Foundation
import GestureEngine

/// One way of turning motion into "that was gesture X".
///
/// Every approach gives each gesture a score at each moment, on one scale:
/// 1 means "at the point this approach itself would fire". The notebook then
/// applies the same firing rule to all of them, so differences come from how
/// they judge movement, not from differences in how they decide to fire.
public protocol Approach {
    var name: String { get }
    var explanation: String { get }
    mutating func train(on data: TrainingSet) throws
    /// Scores for each gesture, judging the movement up to `index`.
    func scores(upTo index: Int, in samples: [MotionSample]) -> [String: Double]
}

// MARK: - Matching against examples

/// The approach already in the app: compare against each recorded example,
/// allowing for speed differences, and fire when close enough.
public struct ExampleMatching: Approach {
    let exampleLimit: Int?

    public init(exampleLimit: Int?) {
        self.exampleLimit = exampleLimit
    }
    var models: [String: GestureModel] = [:]

    public var name: String { exampleLimit.map { "examples (\($0) each)" } ?? "examples (all)" }
    public var explanation: String {
        exampleLimit.map { "Matches against just \($0) recorded examples of each gesture, the way someone would use it after a quick setup." }
            ?? "Matches against every training example of each gesture."
    }

    public mutating func train(on data: TrainingSet) throws {
        for gesture in data.gestures {
            let takes = data.takes[gesture]!.map(\.samples)
            models[gesture] = try GestureLearner.learn(from: exampleLimit.map { Array(takes.prefix($0)) } ?? takes)
        }
    }

    public func scores(upTo index: Int, in samples: [MotionSample]) -> [String: Double] {
        // Five seconds at 50 readings a second is more than any model looks at.
        let history = Array(samples[max(0, index - 250)...index])
        return models.mapValues { model in
            guard let distance = model.distance(endingWith: history), distance.isFinite else { return 0 }
            // Capped so one near-perfect match does not stretch the
            // notebook's charts for everything else.
            return min(3, model.matchThreshold / max(distance, 1e-6))
        }
    }
}

// MARK: - Shared by both classifiers

/// Fixed-length windows cut from the recordings, each labelled as a gesture
/// or as ordinary movement. Both classifiers learn from exactly these.
struct LabelledWindows {
    var windows: [ArraySlice<MotionSample>]
    var labels: [String]
    var length: Int

    /// One second: long enough for a double nod, short enough that a quick
    /// clench is not drowned in a long stretch of stillness.
    static let seconds = 1.0

    init(from data: TrainingSet, random: inout SeededRandom, seconds: Double = Self.seconds) throws {
        length = Int((data.readingsPerSecond * seconds).rounded())
        windows = []
        labels = []
        let rate = data.readingsPerSecond

        for gesture in data.gestures {
            // Where the gesture sits inside each take is found with the
            // example matcher's own movement finder, so both approaches agree
            // on what "the gesture" is.
            let takes = data.takes[gesture]!
            let finder = try GestureLearner.learn(from: takes.map(\.samples))
            for take in takes {
                guard let range = finder.movementRange(in: take.samples) else { continue }
                let centre = (range.lowerBound + range.upperBound) / 2
                // The same take at a few small offsets. Live, the window
                // slides past the gesture and is rarely centred on it exactly,
                // so the classifiers need to see off-centre gestures too. It
                // also multiplies the 15 or so takes into more to learn from.
                for shiftSeconds in [-0.2, -0.1, 0, 0.1, 0.2] {
                    let start = centre - length / 2 + Int(shiftSeconds * rate)
                    guard start >= 0, start + length <= take.samples.count else { continue }
                    windows.append(take.samples[start..<(start + length)])
                    labels.append(gesture)
                }
            }
        }

        var ordinary: [ArraySlice<MotionSample>] = []
        let stride = max(1, Int(rate * 0.25))
        for background in data.background where background.count >= length {
            for start in Swift.stride(from: 0, through: background.count - length, by: stride) {
                ordinary.append(background[start..<(start + length)])
            }
        }
        // Capped so ordinary movement does not outnumber the gestures a
        // hundred to one, which teaches a classifier that the safest answer
        // is always "nothing happened".
        let gestureCount = labels.count
        ordinary = Array(ordinary.shuffled(using: &random).prefix(max(gestureCount * 4, 400)))
        windows += ordinary
        labels += Array(repeating: Recording.backgroundLabel, count: ordinary.count)
    }
}

private let channelNames = ["rotationX", "rotationY", "rotationZ", "joltX", "joltY", "joltZ"]

private func channels(_ sample: MotionSample) -> [Double] {
    [sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
     sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z]
}

private func probabilities(from output: MLFeatureProvider, model: MLModel, gestures: [String]) -> [String: Double] {
    let name = model.modelDescription.predictedProbabilitiesName ?? "labelProbability"
    let byLabel = output.featureValue(for: name)?.dictionaryValue ?? [:]
    var result: [String: Double] = [:]
    for gesture in gestures {
        result[gesture] = byLabel[gesture as NSString]?.doubleValue ?? byLabel[AnyHashable(gesture)]?.doubleValue ?? 0
    }
    return result
}

// MARK: - Classifier on summary numbers

/// A general-purpose classifier (boosted decision trees) fed a few summary
/// numbers per window: average, spread, highest, lowest and jerkiness of each
/// sensor channel. This is the classic recipe in the earable papers.
public struct SummaryNumbersClassifier: Approach {
    var seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }
    var gestures: [String] = []
    var length = 0
    var model: MLModel?

    public var name: String { "classifier (summary numbers)" }
    public var explanation: String {
        "Boosted decision trees on 32 summary numbers per one-second window. Learns from gestures and from normal use, so it also learns what to ignore."
    }

    static func summary(_ window: ArraySlice<MotionSample>) -> [Double] {
        let rows = window.map(channels)
        var numbers: [Double] = []
        for channel in 0..<channelNames.count {
            let values = rows.map { $0[channel] }
            let mean = values.reduce(0, +) / Double(values.count)
            let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            let jerkiness = zip(values.dropFirst(), values).map { abs($0 - $1) }.reduce(0, +) / Double(max(values.count - 1, 1))
            numbers += [mean, spread, values.min()!, values.max()!, jerkiness]
        }
        // Peak overall turning speed and peak overall jolt, whatever the
        // direction: a tilt to the left and to the right share these.
        numbers.append(rows.map { ($0[0] * $0[0] + $0[1] * $0[1] + $0[2] * $0[2]).squareRoot() }.max()!)
        numbers.append(rows.map { ($0[3] * $0[3] + $0[4] * $0[4] + $0[5] * $0[5]).squareRoot() }.max()!)
        return numbers
    }

    private static func featureName(_ index: Int) -> String { "n\(index)" }

    public mutating func train(on data: TrainingSet) throws {
        var random = SeededRandom(seed: seed)
        let labelled = try LabelledWindows(from: data, random: &random)
        gestures = data.gestures
        length = labelled.length
        let rows = labelled.windows.map(Self.summary)
        var columns: [String: MLDataValueConvertible] = ["label": labelled.labels]
        for index in rows[0].indices {
            columns[Self.featureName(index)] = rows.map { $0[index] }
        }
        let table = try MLDataTable(dictionary: columns)
        let classifier = try MLBoostedTreeClassifier(
            trainingData: table, targetColumn: "label",
            parameters: .init(validation: .none, maxDepth: 6, maxIterations: 60)
        )
        model = classifier.model
    }

    public func scores(upTo index: Int, in samples: [MotionSample]) -> [String: Double] {
        guard let model, index + 1 >= length else { return [:] }
        let numbers = Self.summary(samples[(index + 1 - length)...index])
        var input: [String: Any] = [:]
        for (position, value) in numbers.enumerated() { input[Self.featureName(position)] = value }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input),
              let output = try? model.prediction(from: provider) else { return [:] }
        // Probability 0.5 is where it would call the gesture over ordinary
        // movement, so doubling puts that at 1 on the shared scale.
        return probabilities(from: output, model: model, gestures: gestures).mapValues { $0 * 2 }
    }
}

// MARK: - Apple's activity classifier

/// Create ML's activity classifier: a small neural network Apple built for
/// exactly this kind of motion-sensor stream. It reads the raw readings
/// rather than summary numbers, so it can pick up shapes the summary loses,
/// but it usually wants more examples to do so.
public struct ActivityClassifier: Approach {
    var seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }
    var gestures: [String] = []
    var length = 0
    var model: MLModel?

    public var name: String { "classifier (Apple activity)" }
    public var explanation: String {
        "Create ML's activity classifier, a small neural network on the raw one-second window. Also learns from normal use."
    }

    public mutating func train(on data: TrainingSet) throws {
        var random = SeededRandom(seed: seed)
        let labelled = try LabelledWindows(from: data, random: &random)
        gestures = data.gestures
        length = labelled.length

        // Create ML cuts each training recording into pieces one model
        // window long, starting from the beginning. Two layouts failed:
        //  - one window per recording trained without complaint but gave
        //    the same answer for every input;
        //  - two seconds centred on the gesture put the gesture exactly on
        //    the cut, so the model learnt the stillness either side of a
        //    clench as "clench", and scored real clenches at zero.
        // So each recording is up to five windows laid end to end, each one
        // already centred on its gesture (the shifted copies of one take, or
        // stretches of ordinary use). Every piece Create ML cuts is then a
        // whole window with the gesture inside it.
        var recordings: [(label: String, windows: [ArraySlice<MotionSample>])] = []
        for (window, label) in zip(labelled.windows, labelled.labels) {
            if let last = recordings.last, last.label == label, last.windows.count < 5 {
                recordings[recordings.count - 1].windows.append(window)
            } else {
                recordings.append((label, [window]))
            }
        }
        var columns: [String: MLDataValueConvertible] = [
            "session": recordings.indices.map { "recording \($0)" },
            "label": recordings.map(\.label),
        ]
        for (channel, name) in channelNames.enumerated() {
            columns[name] = recordings.map { recording in recording.windows.flatMap { $0.map { channels($0)[channel] } } }
        }
        let table = try MLDataTable(dictionary: columns)
        let classifier = try MLActivityClassifier(
            trainingData: table, featureColumns: channelNames, labelColumn: "label",
            recordingFileColumn: "session",
            parameters: .init(validation: .none, batchSize: 32, maximumIterations: 40, predictionWindowSize: length)
        )
        model = classifier.model
    }

    public func scores(upTo index: Int, in samples: [MotionSample]) -> [String: Double] {
        guard let model, index + 1 >= length else { return [:] }
        let window = samples[(index + 1 - length)...index]
        var input: [String: Any] = [:]
        for (channel, name) in channelNames.enumerated() {
            guard let array = try? MLMultiArray(shape: [NSNumber(value: length)], dataType: .double) else { return [:] }
            for (position, sample) in window.enumerated() { array[position] = NSNumber(value: channels(sample)[channel]) }
            input[name] = array
        }
        // The network carries memory from one window to the next. Every
        // window here starts from a blank memory instead, so it judges each
        // second on its own, the same as the other approaches.
        for (name, description) in model.modelDescription.inputDescriptionsByName where input[name] == nil {
            if let constraint = description.multiArrayConstraint,
               let blank = try? MLMultiArray(shape: constraint.shape, dataType: .double) {
                for position in 0..<blank.count { blank[position] = 0 }
                input[name] = blank
            }
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input),
              let output = try? model.prediction(from: provider) else { return [:] }
        return probabilities(from: output, model: model, gestures: gestures).mapValues { $0 * 2 }
    }
}
