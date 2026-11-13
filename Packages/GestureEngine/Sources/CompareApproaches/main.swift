// Trains every approach on the same recordings, runs each over the same
// unseen test stream, and writes what each one scored, moment by moment.
//
//   compare-approaches <recordings folder> <output folder> [seed]
//
// Firing and counting hits are left to the notebook on purpose, so the firing
// threshold can be changed there and the effect seen without retraining.
import Foundation
import GestureEngine

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    say("usage: compare-approaches <recordings folder> <output folder> [seed]")
    exit(2)
}
let recordingsFolder = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
let outputFolder = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath)
let seed = arguments.count > 3 ? UInt64(arguments[3]) ?? 1 : 1
/// Three in ten held back for testing: enough unseen takes to count misses,
/// while leaving most for learning.
let testFraction = 0.3

var random = SeededRandom(seed: seed)
let data: Dataset
do {
    data = try loadDataset(folder: recordingsFolder, testFraction: testFraction, random: &random)
} catch {
    // Named plainly rather than as a stack trace: the usual cause is simply
    // not having recorded enough yet.
    say("Cannot compare yet: \(error)")
    exit(1)
}

say(String(format: "%.0f readings a second; test stream %.1f minutes with %d gestures spliced in",
           data.readingsPerSecond, Double(data.test.samples.count) / data.readingsPerSecond / 60, data.test.events.count))
for gesture in data.gestures {
    say("  \(gesture): \(data.trainingTakes[gesture]!.count) to learn from, \(data.testTakes[gesture]!.count) held back")
}
for (gesture, count) in data.skippedGestures.sorted(by: { $0.key < $1.key }) {
    say("  skipped \(gesture): only \(count) takes, needs \(minimumTakesPerGesture)")
}

var approaches: [any Approach] = [
    ExampleMatching(exampleLimit: 3),
    ExampleMatching(exampleLimit: nil),
    SummaryNumbersClassifier(seed: seed),
    ActivityClassifier(seed: seed),
]

/// Scores every tenth of a second rather than at every reading: plenty to
/// place a fire in time, and a tenth of the work.
let stride = max(1, Int((data.readingsPerSecond * 0.1).rounded()))
let ticks = Array(Swift.stride(from: 0, to: data.test.samples.count, by: stride))

var scoreLines = ["approach,gesture,time,score"]
var approachSummaries: [[String: Any]] = []
// Kept in the results, not just printed: a failure that only scrolled past in
// the tool's output once left the notebook quietly comparing one approach.
var failedApproaches: [[String: String]] = []
for index in approaches.indices {
    let name = approaches[index].name
    say("\(name): training")
    let trainingStart = Date()
    do {
        try approaches[index].train(on: data)
    } catch {
        say("\(name): training failed: \(error)")
        failedApproaches.append(["name": name, "error": "\(error)"])
        continue
    }
    let trainingSeconds = Date().timeIntervalSince(trainingStart)
    say(String(format: "%@: trained in %.1f s, scoring %d moments", name, trainingSeconds, ticks.count))

    let scoringStart = Date()
    for (count, tick) in ticks.enumerated() {
        let time = data.test.samples[tick].timestamp
        for (gesture, score) in approaches[index].scores(upTo: tick, in: data.test.samples) {
            scoreLines.append("\(name),\(gesture),\(String(format: "%.2f", time)),\(String(format: "%.4f", score))")
        }
        if count > 0, count % 1000 == 0 {
            say(String(format: "%@: %d%% scored", name, count * 100 / ticks.count))
        }
    }
    let microsecondsPerMoment = Date().timeIntervalSince(scoringStart) / Double(ticks.count) * 1_000_000
    approachSummaries.append([
        "name": name,
        "explanation": approaches[index].explanation,
        "trainingSeconds": trainingSeconds,
        "microsecondsPerMoment": microsecondsPerMoment,
    ])
}

try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
try scoreLines.joined(separator: "\n").write(to: outputFolder.appendingPathComponent("scores.csv"), atomically: true, encoding: .utf8)

var streamLines = ["time,rotationX,rotationY,rotationZ,joltX,joltY,joltZ"]
for sample in data.test.samples {
    let values = [sample.timestamp, sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
                  sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z]
    streamLines.append(values.map { String(format: "%.5f", $0) }.joined(separator: ","))
}
try streamLines.joined(separator: "\n").write(to: outputFolder.appendingPathComponent("stream.csv"), atomically: true, encoding: .utf8)

var eventLines = ["gesture,promptTime,takeEnd"]
for event in data.test.events {
    eventLines.append("\(event.label),\(String(format: "%.2f", event.promptTime)),\(String(format: "%.2f", event.takeEnd))")
}
try eventLines.joined(separator: "\n").write(to: outputFolder.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)

let summary: [String: Any] = [
    "seed": seed,
    "readingsPerSecond": data.readingsPerSecond,
    "testFraction": testFraction,
    "backgroundTestSeconds": data.test.backgroundSeconds,
    "backgroundTrainingSeconds": Double(data.trainingBackground.map(\.count).reduce(0, +)) / data.readingsPerSecond,
    "gestures": data.gestures.map { ["name": $0, "training": data.trainingTakes[$0]!.count, "test": data.testTakes[$0]!.count] },
    "skippedGestures": data.skippedGestures,
    "approaches": approachSummaries,
    "failedApproaches": failedApproaches,
    // Takes the example matcher found no movement in, per gesture, counting
    // from 1 within that gesture's training takes. Both classifiers locate
    // gestures with the same matcher, so they skip the same takes.
    "skippedTakes": Dictionary(uniqueKeysWithValues: data.gestures.map { gesture in
        (gesture, (try? GestureLearner.learn(from: data.trainingTakes[gesture]!.map(\.samples)))?.skippedExampleNumbers ?? [])
    }),
]
try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputFolder.appendingPathComponent("summary.json"))
say("Wrote results to \(outputFolder.path)")
