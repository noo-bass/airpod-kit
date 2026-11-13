import AppKit
import Foundation
import GestureEngine
import GestureLearning
import Observation
import os

/// Runs one approach live on the AirPods stream, so it can be judged in real
/// use rather than only on held-back recordings.
///
/// Uses the same approaches, the same scores and the same firing rule as the
/// comparison notebook, so what you see here can be checked against it.
@MainActor
@Observable
final class LiveTrial {
    enum Choice: String, CaseIterable, Identifiable {
        case examples = "Matching 3 examples"
        case trees = "Tree classifier"
        case apple = "Apple's classifier"

        var id: String { rawValue }

        func makeApproach() -> any Approach {
            switch self {
            case .examples: ExampleMatching(exampleLimit: 3)
            case .trees: SummaryNumbersClassifier(seed: 1)
            case .apple: ActivityClassifier(seed: 1)
            }
        }

        /// Starting thresholds, taken from the comparison notebook's
        /// "Could any threshold separate them?" table on the first real
        /// recordings. Both classifiers are overconfident: real gestures and
        /// their worst false alarms both score near 2 (99.9% sure), so their
        /// useful threshold sits right at the top of the scale.
        var suggestedThreshold: Double {
            switch self {
            case .examples: 0.9
            case .trees, .apple: 1.99
            }
        }

        var needsNormalUse: Bool { self != .examples }
    }

    enum State: Equatable {
        case untrained
        case training
        case ready(summary: String)
        case failed(message: String)
    }

    struct Fire: Identifiable {
        let id = UUID()
        let gesture: String
        let date: Date
        let score: Double
    }

    private(set) var choice: Choice = .trees
    private(set) var state: State = .untrained
    private(set) var gestures: [String] = []
    private(set) var liveScores: [String: Double] = [:]
    private(set) var fires: [Fire] = []
    var threshold: Double = Choice.trees.suggestedThreshold
    var isListening = true

    /// Long enough that one nod cannot fire twice, short enough for a quick
    /// double clench to register as two. Same as the notebook's default.
    let cooldownSeconds = 0.8

    /// Training results and fires also go to the system log, so a live
    /// session can be checked from a terminal with `log stream`.
    private static let log = Logger(subsystem: "io.github.noo-bass.airpodkit", category: "trial")

    @ObservationIgnored private var approach: (any Approach)?
    @ObservationIgnored private var history: [MotionSample] = []
    @ObservationIgnored private var readingsSinceCheck = 0
    @ObservationIgnored private var quietUntil: [String: TimeInterval] = [:]
    /// Bumped on every training run, so a slow run that finishes after the
    /// user has already picked another approach is thrown away.
    @ObservationIgnored private var trainingRun = 0

    func select(_ newChoice: Choice, store: RecordingStore) {
        choice = newChoice
        threshold = newChoice.suggestedThreshold
        train(using: store)
    }

    func train(using store: RecordingStore) {
        trainingRun += 1
        let run = trainingRun
        let choice = choice
        let recordings = store.loadAllRecordings()
        approach = nil
        liveScores = [:]
        state = .training

        Task.detached(priority: .userInitiated) {
            let outcome: Result<(any Approach, TrainingSet), Error>
            do {
                // All recordings this time, with nothing held back: this is
                // the real thing, not the comparison's fair test.
                let set = TrainingSet(recordings: recordings, minimumTakes: 3)
                guard !set.gestures.isEmpty else { throw LiveTrialError.noGestures }
                guard !choice.needsNormalUse || !set.background.isEmpty else { throw LiveTrialError.noNormalUse }
                var approach = choice.makeApproach()
                try approach.train(on: set)
                outcome = .success((approach, set))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self.finishTraining(outcome, run: run) }
        }
    }

    private func finishTraining(_ outcome: Result<(any Approach, TrainingSet), Error>, run: Int) {
        guard run == trainingRun else { return }
        switch outcome {
        case let .success((trained, set)):
            approach = trained
            gestures = set.gestures
            history = []
            quietUntil = [:]
            let takes = set.gestures.map { "\(set.takes[$0]?.count ?? 0) \($0)" }.joined(separator: ", ")
            let minutes = Double(set.background.map(\.count).reduce(0, +)) / set.readingsPerSecond / 60
            state = .ready(summary: choice.needsNormalUse
                ? "Trained on \(takes) takes and \(Int(minutes.rounded())) minutes of normal use."
                : "Trained on the first 3 takes of each gesture.")
            Self.log.info("trained \(self.choice.rawValue, privacy: .public): \(takes, privacy: .public)")
        case let .failure(error):
            state = .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            Self.log.error("training \(self.choice.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    func clearFires() {
        fires = []
    }

    func receive(_ sample: MotionSample) {
        guard isListening, let approach else { return }
        history.append(sample)
        if let firstKept = history.firstIndex(where: { sample.timestamp - $0.timestamp <= 5 }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
        // Checked ten times a second at 50 readings a second, as in the
        // comparison, which is also what keeps the cost negligible.
        readingsSinceCheck += 1
        guard readingsSinceCheck >= 5 else { return }
        readingsSinceCheck = 0

        let scores = approach.scores(upTo: history.count - 1, in: history)
        liveScores = scores
        for (gesture, score) in scores where score >= threshold && sample.timestamp >= (quietUntil[gesture] ?? 0) {
            quietUntil[gesture] = sample.timestamp + cooldownSeconds
            fires.insert(Fire(gesture: gesture, date: Date(), score: score), at: 0)
            if fires.count > 100 { fires.removeLast() }
            NSSound(named: "Pop")?.play()
            Self.log.info("fired \(gesture, privacy: .public) score \(score, privacy: .public) threshold \(self.threshold, privacy: .public) approach \(self.choice.rawValue, privacy: .public)")
        }
    }
}

enum LiveTrialError: LocalizedError {
    case noGestures
    case noNormalUse

    var errorDescription: String? {
        switch self {
        case .noGestures: "Record at least 3 takes of a gesture first."
        case .noNormalUse: "This approach also learns from normal use. Record some on the Record screen first."
        }
    }
}
