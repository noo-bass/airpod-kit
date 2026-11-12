import Charts
import GestureEngine
import SwiftUI

struct LiveSensorsView: View {
    @Environment(AirPodKit.self) private var kit

    var body: some View {
        let samples = kit.motion.recentSamples
        let newest = samples.last?.timestamp ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Move your head or clench your jaw and watch the lines. Gestures you want to teach need to show up clearly here first.")
                    .foregroundStyle(.secondary)

                SensorChart(
                    title: "Turning speed",
                    unit: "radians per second",
                    explanation: "Nods, shakes and tilts.",
                    points: points(samples, newest: newest) { $0.rotationRate }
                )
                SensorChart(
                    title: "Jolts",
                    unit: "g, gravity removed",
                    explanation: "Small sharp nudges to the earbud, like a jaw clench or a tap.",
                    points: points(samples, newest: newest) { $0.userAcceleration }
                )
            }
            .padding(24)
        }
        .navigationTitle("Live sensors")
    }

    private func points(_ samples: [MotionSample], newest: TimeInterval, _ pick: (MotionSample) -> Vector3) -> [SensorChart.Point] {
        samples.flatMap { sample -> [SensorChart.Point] in
            let value = pick(sample)
            let secondsAgo = sample.timestamp - newest
            return [
                .init(secondsAgo: secondsAgo, axis: "x", value: value.x),
                .init(secondsAgo: secondsAgo, axis: "y", value: value.y),
                .init(secondsAgo: secondsAgo, axis: "z", value: value.z),
            ]
        }
    }
}

struct SensorChart: View {
    struct Point: Identifiable {
        let secondsAgo: Double
        let axis: String
        let value: Double
        var id: String { "\(axis)\(secondsAgo)" }
    }

    let title: String
    let unit: String
    let explanation: String
    let points: [Point]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            Chart(points) { point in
                LineMark(
                    x: .value("Seconds ago", point.secondsAgo),
                    y: .value(title, point.value)
                )
                .foregroundStyle(by: .value("Axis", point.axis))
                .interpolationMethod(.linear)
            }
            .chartXScale(domain: -6...0)
            .chartXAxisLabel("seconds ago")
            .frame(height: 180)
        }
    }
}
