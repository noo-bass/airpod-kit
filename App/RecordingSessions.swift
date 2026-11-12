import AppKit
import Foundation
import GestureEngine
import Observation

/// Walks the user through a run of prompted takes of one gesture:
/// "get ready" (stay still), then "now" (do it once), then a short break.
@MainActor
@Observable
final class TakeSession {
    enum Phase: Equatable {
        case idle
        case getReady(take: Int)
        case now(take: Int)
        case resting(take: Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var label = ""
    private(set) var totalTakes = 0

    @ObservationIgnored private var collected: [MotionSample] = []
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var runner: Task<Void, Never>?

    /// The stillness before "now" is recorded too. The classifier needs to
    /// see where the gesture starts, and the example matcher trims to the
    /// movement by contrasting it with the stillness around it.
    static let readySeconds = 1.2
    /// Long enough for a slow double nod plus reaction time, short enough
    /// that the user does not fidget into the end of the take.
    static let nowSeconds = 2.0
    static let restSeconds = 0.8

    var isRunning: Bool { phase != .idle }

    func start(label: String, takes: Int, saveTo store: RecordingStore) {
        guard !isRunning else { return }
        self.label = label
        totalTakes = takes
        runner = Task { [weak self] in
            for take in 1...takes {
                guard let self, !Task.isCancelled else { return }
                self.collected = []
                self.collecting = true
                self.phase = .getReady(take: take)
                try? await Task.sleep(for: .seconds(Self.readySeconds))
                guard !Task.isCancelled else { return }

                self.phase = .now(take: take)
                // A sound as well as the on-screen cue, so a gesture that
                // needs your eyes closed or turned away can still be timed.
                NSSound(named: "Tink")?.play()
                try? await Task.sleep(for: .seconds(Self.nowSeconds))
                guard !Task.isCancelled else { return }

                self.collecting = false
                store.save(Recording(label: label, kind: .take,
                                     promptOffset: Self.readySeconds, samples: self.collected))
                self.phase = .resting(take: take)
                try? await Task.sleep(for: .seconds(Self.restSeconds))
            }
            self?.phase = .idle
        }
    }

    /// Stops after the current take; a half-finished take is thrown away
    /// rather than saved, since it would teach a cut-off gesture.
    func cancel() {
        runner?.cancel()
        runner = nil
        collecting = false
        collected = []
        phase = .idle
    }

    func receive(_ sample: MotionSample) {
        if collecting { collected.append(sample) }
    }
}

/// Records ordinary use for as long as the user likes.
@MainActor
@Observable
final class BackgroundSession {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    @ObservationIgnored private var collected: [MotionSample] = []

    func start() {
        collected = []
        startedAt = Date()
        isRecording = true
    }

    func stop(saveTo store: RecordingStore) {
        guard isRecording else { return }
        isRecording = false
        startedAt = nil
        // Under ten seconds is almost certainly a mis-click, and too short to
        // teach anything about ordinary movement.
        if let first = collected.first, let last = collected.last, last.timestamp - first.timestamp >= 10 {
            store.save(Recording(label: Recording.backgroundLabel, kind: .background, samples: collected))
        }
        collected = []
    }

    func receive(_ sample: MotionSample) {
        if isRecording { collected.append(sample) }
    }
}
