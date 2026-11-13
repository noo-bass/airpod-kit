import GestureEngine
import SwiftUI

struct TryItView: View {
    @Environment(AirPodKit.self) private var kit

    var body: some View {
        @Bindable var trial = kit.trial
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Pick an approach, then use it for real: do each gesture a few times, then just carry on working for a few minutes. Every fire makes a sound and is listed below, so you can see what it catches and what it fires on by mistake.")
                    .foregroundStyle(.secondary)

                if kit.motion.status != .streaming {
                    Label("No readings from your AirPods. Put them in, or connect them from the Bluetooth menu.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Approach", selection: Binding(
                        get: { trial.choice },
                        set: { trial.select($0, store: kit.store) }
                    )) {
                        ForEach(LiveTrial.Choice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(trial.state == .training)

                    TrainingStatus(state: trial.state) { trial.train(using: kit.store) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fire when score reaches")
                        Slider(value: $trial.threshold, in: 0.3...2.0)
                        Text(String(format: "%.2f", trial.threshold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("Raise it if it fires when you did nothing; lower it if it misses your gestures. The starting value comes from the comparison notebook. The classifiers are very sure of themselves, so for them the useful range is right at the top, around 1.97 to 2.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Listening", isOn: $trial.isListening)
                }

                if !trial.gestures.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Live").font(.headline)
                        ForEach(trial.gestures, id: \.self) { gesture in
                            ScoreBar(
                                gesture: gesture,
                                score: trial.liveScores[gesture] ?? 0,
                                threshold: trial.threshold,
                                fireCount: trial.fires.filter { $0.gesture == gesture }.count
                            )
                        }
                    }
                }

                FireLog(fires: trial.fires) { trial.clearFires() }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .navigationTitle("Try it")
        .onAppear {
            if trial.state == .untrained { trial.train(using: kit.store) }
        }
    }
}

private struct TrainingStatus: View {
    let state: LiveTrial.State
    let retrain: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .untrained:
                Text("Not trained yet.").foregroundStyle(.secondary)
            case .training:
                ProgressView().controlSize(.small)
                Text("Training on your recordings. Apple's classifier takes up to half a minute.")
                    .foregroundStyle(.secondary)
            case let .ready(summary):
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text(summary).foregroundStyle(.secondary)
            case let .failed(message):
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text(message)
            }
            Spacer()
            Button("Retrain", action: retrain)
                .disabled(state == .training)
                .help("Train again, for example after recording more takes.")
        }
        .font(.callout)
    }
}

/// One gesture's live score, with the firing threshold marked on it.
private struct ScoreBar: View {
    let gesture: String
    let score: Double
    let threshold: Double
    let fireCount: Int

    /// Scores run from 0 to 2 for every approach (2 is a certain classifier,
    /// or a very close match), so the bar is drawn on that range.
    private let scaleTop = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(gesture)
                Spacer()
                Text(String(format: "%.2f", score)).monospacedDigit().foregroundStyle(.secondary)
                Text("\(fireCount) fired").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(score >= threshold ? Color.green : Color.accentColor)
                        .frame(width: proxy.size.width * min(max(score / scaleTop, 0), 1))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: proxy.size.width * min(threshold / scaleTop, 1) - 1)
                }
            }
            .frame(height: 10)
        }
    }
}

private struct FireLog: View {
    let fires: [LiveTrial.Fire]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fired").font(.headline)
                Spacer()
                Button("Clear", action: clear).disabled(fires.isEmpty)
            }
            if fires.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(fires) { fire in
                HStack {
                    Text(fire.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(fire.gesture)
                    Spacer()
                    Text(String(format: "score %.3f", fire.score))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
