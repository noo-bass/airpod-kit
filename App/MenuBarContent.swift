import SwiftUI

struct MenuBarContent: View {
    @Environment(AirPodKit.self) private var kit
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if kit.background.isRecording {
            Button("Stop recording normal use") { kit.background.stop(saveTo: kit.store) }
        }
        Divider()
        Button("Open AirPod Kit") {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Quit AirPod Kit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch kit.motion.status {
        case .streaming: kit.background.isRecording ? "Recording normal use" : "AirPods streaming"
        case .waitingForAirPods: "Waiting for AirPods"
        case .permissionDenied: "Motion access is off"
        case .notSupported: "No motion sensors"
        case .starting: "Starting"
        }
    }
}
