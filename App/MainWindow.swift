import GestureEngine
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    enum Section: Hashable {
        case live
        case record
        case tryIt
    }

    @Environment(AirPodKit.self) private var kit
    @State private var section: Section? = .live

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Live sensors", systemImage: "waveform.path.ecg").tag(Section.live)
                Label("Record", systemImage: "record.circle").tag(Section.record)
                Label("Try it", systemImage: "hand.tap").tag(Section.tryIt)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                ConnectionStatusView()
                    .padding(12)
            }
        } detail: {
            switch section ?? .live {
            case .live: LiveSensorsView()
            case .record: RecordView()
            case .tryIt: TryItView()
            }
        }
    }
}

struct ConnectionStatusView: View {
    @Environment(AirPodKit.self) private var kit

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(kit.motion.status == .streaming ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch kit.motion.status {
        case .starting: "Starting"
        case .notSupported: "No motion sensors"
        case .permissionDenied: "Motion access is off"
        case .waitingForAirPods: "Waiting for AirPods"
        case .streaming: "AirPods streaming"
        }
    }

    private var detail: String? {
        switch kit.motion.status {
        case .streaming: "\(Int(kit.motion.readingsPerSecond)) readings a second"
        case .waitingForAirPods: "Put them in. Needs AirPods Pro, Max, or 3rd gen and later."
        case .permissionDenied: "System Settings > Privacy & Security > Motion & Fitness"
        case .notSupported: "This Mac reports no headphone motion support."
        case .starting: nil
        }
    }
}
