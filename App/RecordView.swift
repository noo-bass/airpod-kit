import AppKit
import GestureEngine
import SwiftUI

struct RecordView: View {
    @Environment(AirPodKit.self) private var kit
    @State private var gestureName = ""
    @State private var takeCount = 20

    private var streaming: Bool { kit.motion.status == .streaming }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Two kinds of recording teach the app. Takes show it what a gesture looks like. Normal use shows it what to ignore, which matters just as much: without it, any movement can look like a gesture.")
                    .foregroundStyle(.secondary)

                takesSection
                Divider()
                backgroundSection
                Divider()
                savedSection
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle("Record")
    }

    // MARK: Takes

    @ViewBuilder private var takesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gesture takes").font(.title3.bold())
            Text("Stay still while it says Get ready. When you hear the sound, do the gesture once. About 20 takes per gesture gives the trained classifier enough to learn from; the example matcher needs only 3.")
                .font(.callout).foregroundStyle(.secondary)

            if kit.takes.isRunning {
                TakePrompt()
            } else {
                HStack {
                    TextField("Gesture name, e.g. double nod", text: $gestureName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Stepper("\(takeCount) takes", value: $takeCount, in: 3...50)
                        .fixedSize()
                    Button("Start") {
                        kit.takes.start(label: trimmedName, takes: takeCount, saveTo: kit.store)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!streaming || trimmedName.isEmpty || trimmedName == Recording.backgroundLabel)
                }
                if !kit.store.takeCounts.isEmpty {
                    HStack(spacing: 6) {
                        Text("Add more to:").font(.caption).foregroundStyle(.secondary)
                        ForEach(kit.store.takeCounts, id: \.label) { entry in
                            Button(entry.label) { gestureName = entry.label }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var trimmedName: String {
        gestureName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Background

    @ViewBuilder private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Normal use").font(.title3.bold())
            Text("Start this, then carry on as usual with your AirPods in: type, read, talk, drink, look around, turn to someone. Do not do any of your gestures. Ten minutes or more, spread over a few sessions, is a good start.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if kit.background.isRecording {
                    Button("Stop and save") { kit.background.stop(saveTo: kit.store) }
                    if let startedAt = kit.background.startedAt {
                        HStack(spacing: 6) {
                            Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            Text(startedAt, style: .timer).monospacedDigit()
                        }
                    }
                } else {
                    Button("Start recording normal use") { kit.background.start() }
                        .disabled(!streaming || kit.takes.isRunning)
                }
            }
            Text("You can close this window while it records; it keeps going from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Saved

    @ViewBuilder private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved").font(.title3.bold())
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: kit.store.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([kit.store.folder])
                }
            }
            if let error = kit.store.lastError {
                Text(error).foregroundStyle(.red)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(kit.store.takeCounts, id: \.label) { entry in
                    GridRow {
                        Text(entry.label)
                        Text("\(entry.count) takes").monospacedDigit().foregroundStyle(.secondary)
                        Button("Delete all", role: .destructive) { kit.store.deleteAll(label: entry.label) }
                            .buttonStyle(.link)
                    }
                }
                GridRow {
                    Text("Normal use")
                    Text(String(format: "%.1f minutes", kit.store.backgroundMinutes)).monospacedDigit().foregroundStyle(.secondary)
                    Text("")
                }
            }
        }
    }
}

/// The big cue during a run of takes.
private struct TakePrompt: View {
    @Environment(AirPodKit.self) private var kit

    var body: some View {
        let session = kit.takes
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(cue.text)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(cue.colour)
                Spacer()
                Button("Stop") { kit.takes.cancel() }
            }
            Text("\(session.label): take \(cue.take) of \(session.totalTakes)")
                .foregroundStyle(.secondary)
            ProgressView(value: Double(cue.take - 1), total: Double(session.totalTakes))
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cue: (text: String, colour: Color, take: Int) {
        switch kit.takes.phase {
        case let .getReady(take): ("Get ready", .secondary, take)
        case let .now(take): ("Now", .green, take)
        case let .resting(take): ("Saved", .secondary, take + 1 > kit.takes.totalTakes ? take : take + 1)
        case .idle: ("", .secondary, 1)
        }
    }
}
