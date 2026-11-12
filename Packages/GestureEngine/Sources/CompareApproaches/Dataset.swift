import Foundation
import GestureEngine

/// The recordings, split into a part each approach learns from and a part
/// none of them has seen, plus the test stream built from the unseen part.
struct Dataset {
    var gestures: [String]
    var trainingTakes: [String: [Recording]]
    var testTakes: [String: [Recording]]
    var trainingBackground: [[MotionSample]]
    var readingsPerSecond: Double
    var test: TestStream
    var skippedGestures: [String: Int]
}

/// Held-out ordinary use with held-out takes spliced in at known moments.
///
/// This is the closest offline stand-in for real use: long stretches of
/// ordinary movement the approaches must stay quiet through, with the
/// occasional real gesture they must catch. Splicing is a simplification:
/// in real life a gesture happens mid-movement, while each take was done from
/// stillness, so these numbers are likely a little better than real use.
struct TestStream {
    struct Event {
        var label: String
        /// When the user was told "now".
        var promptTime: TimeInterval
        /// End of the inserted take.
        var takeEnd: TimeInterval
    }

    var samples: [MotionSample]
    var events: [Event]
    var backgroundSeconds: TimeInterval
}

enum DatasetError: Error, CustomStringConvertible {
    case folderMissing(URL)
    case noBackground
    case noGestures(minimumTakes: Int)

    var description: String {
        switch self {
        case let .folderMissing(url):
            "No recordings folder at \(url.path). Record some in the app first."
        case .noBackground:
            "No normal-use recording yet. Both classifiers need one to learn what to ignore, and the test needs one to count false triggers."
        case let .noGestures(minimumTakes):
            "No gesture has \(minimumTakes) takes yet. Each needs enough to learn from and some held back to test on."
        }
    }
}

/// Fewer than this and there is nothing worth holding back for testing.
let minimumTakesPerGesture = 6

func loadDataset(folder: URL, testFraction: Double, random: inout SeededRandom) throws -> Dataset {
    guard FileManager.default.fileExists(atPath: folder.path) else { throw DatasetError.folderMissing(folder) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recordings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try decoder.decode(Recording.self, from: Data(contentsOf: $0)) }
        .filter { $0.samples.count > 1 }

    let backgrounds = recordings.filter { $0.kind == .background }
    guard !backgrounds.isEmpty else { throw DatasetError.noBackground }

    let takesByLabel = Dictionary(grouping: recordings.filter { $0.kind == .take }, by: \.label)
    let gestures = takesByLabel.filter { $0.value.count >= minimumTakesPerGesture }.keys.sorted()
    guard !gestures.isEmpty else { throw DatasetError.noGestures(minimumTakes: minimumTakesPerGesture) }
    let skipped = takesByLabel.filter { $0.value.count < minimumTakesPerGesture }.mapValues(\.count)

    var trainingTakes: [String: [Recording]] = [:]
    var testTakes: [String: [Recording]] = [:]
    for gesture in gestures {
        let shuffled = takesByLabel[gesture]!.shuffled(using: &random)
        let testCount = max(2, Int((Double(shuffled.count) * testFraction).rounded()))
        testTakes[gesture] = Array(shuffled.prefix(testCount))
        trainingTakes[gesture] = Array(shuffled.dropFirst(testCount))
    }

    // Each normal-use recording is split by time, not by shuffling short
    // pieces: neighbouring seconds of ordinary movement look alike, so
    // shuffled pieces would leak near-copies of the test into training.
    var trainingBackground: [[MotionSample]] = []
    var testBackground: [[MotionSample]] = []
    for background in backgrounds {
        let cut = Int(Double(background.samples.count) * (1 - testFraction))
        trainingBackground.append(Array(background.samples[..<cut]))
        testBackground.append(Array(background.samples[cut...]))
    }

    let allIntervals = recordings.flatMap { recording in
        zip(recording.samples.dropFirst(), recording.samples).map { $0.timestamp - $1.timestamp }
    }.filter { $0 > 0 }
    let readingsPerSecond = 1 / allIntervals.sorted()[allIntervals.count / 2]

    let test = buildTestStream(
        background: testBackground,
        takes: gestures.flatMap { testTakes[$0]! }.shuffled(using: &random),
        readingsPerSecond: readingsPerSecond
    )
    return Dataset(gestures: gestures, trainingTakes: trainingTakes, testTakes: testTakes,
                   trainingBackground: trainingBackground, readingsPerSecond: readingsPerSecond,
                   test: test, skippedGestures: skipped)
}

private func buildTestStream(background: [[MotionSample]], takes: [Recording], readingsPerSecond: Double) -> TestStream {
    let ordinary = background.flatMap { $0 }
    let step = 1 / readingsPerSecond
    // Takes spread evenly through the ordinary movement, so each approach has
    // to stay quiet between them for a realistic length of time.
    let gap = ordinary.count / (takes.count + 1)

    var samples: [MotionSample] = []
    var events: [TestStream.Event] = []
    var cursor = 0
    func append(_ sample: MotionSample) {
        // Re-timed onto one clock: the pieces came from different sessions.
        var retimed = sample
        retimed.timestamp = Double(samples.count) * step
        samples.append(retimed)
    }
    for take in takes {
        for sample in ordinary[cursor..<min(cursor + gap, ordinary.count)] { append(sample) }
        cursor += gap
        let start = Double(samples.count) * step
        for sample in take.samples { append(sample) }
        events.append(.init(label: take.label, promptTime: start + (take.promptOffset ?? 0),
                            takeEnd: Double(samples.count) * step))
    }
    for sample in ordinary[min(cursor, ordinary.count)...] { append(sample) }
    return TestStream(samples: samples, events: events, backgroundSeconds: Double(ordinary.count) * step)
}

/// Repeatable shuffles, so the same recordings always give the same split
/// and two runs can be compared.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
