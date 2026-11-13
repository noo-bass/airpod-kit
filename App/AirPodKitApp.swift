import GestureEngine
import SwiftUI

@main
struct AirPodKitApp: App {
    @State private var kit = AirPodKit()

    var body: some Scene {
        Window("AirPod Kit", id: MainWindow.id) {
            MainWindow()
                .environment(kit)
        }
        .defaultSize(width: 900, height: 620)

        // The menu bar icon keeps the app reachable after the window is
        // closed, which is the normal state once gestures are set up.
        MenuBarExtra {
            MenuBarContent()
                .environment(kit)
        } label: {
            Image(systemName: kit.motion.status == .streaming ? "airpodspro" : "airpodspro.chargingcase.wireless")
        }
    }
}

/// Everything the views share, wired together once.
@MainActor
@Observable
final class AirPodKit {
    let motion = HeadphoneMotionSource()
    let store = RecordingStore()
    let takes = TakeSession()
    let background = BackgroundSession()
    let trial = LiveTrial()

    init() {
        motion.onSample = { [takes, background, trial] sample in
            takes.receive(sample)
            background.receive(sample)
            trial.receive(sample)
        }
        motion.start()
    }
}
