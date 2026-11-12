import CoreMotion
import Foundation
import GestureEngine
import Observation
import os

/// Streams motion readings from whichever AirPods are connected.
@MainActor
@Observable
final class HeadphoneMotionSource {
    enum Status: Equatable {
        case starting
        /// This Mac or these headphones have no motion sensors Apple exposes.
        case notSupported
        /// The user said no to Motion & Fitness access in System Settings.
        case permissionDenied
        case waitingForAirPods
        case streaming
    }

    private(set) var status: Status = .starting {
        // Logged so connection trouble can be read with `log show` from a
        // terminal, without needing to see the window.
        didSet { if status != oldValue { Self.log.info("motion status: \(String(describing: self.status), privacy: .public)") } }
    }
    private static let log = Logger(subsystem: "io.github.noo-bass.airpodkit", category: "motion")
    /// The last few seconds, for the live graphs. Refreshed a few times a
    /// second rather than on every reading: redrawing two charts 25 times a
    /// second costs more CPU than everything else in the app together.
    private(set) var recentSamples: [MotionSample] = []
    private(set) var readingsPerSecond: Double = 0

    /// Called for every reading, on the main thread.
    @ObservationIgnored var onSample: ((MotionSample) -> Void)?

    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    @ObservationIgnored private let connectionWatcher = ConnectionWatcher()
    @ObservationIgnored private var buffer: [MotionSample] = []
    @ObservationIgnored private var lastReadingAt: Date?
    @ObservationIgnored private var readingsSinceLastTick = 0
    @ObservationIgnored private var heartbeat: Timer?

    private let graphSeconds: TimeInterval = 6

    func start() {
        guard manager.isDeviceMotionAvailable else {
            status = .notSupported
            return
        }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = .permissionDenied
            return
        default:
            break
        }

        // The delegate is called on whatever thread CoreMotion likes, so hop
        // rather than assume.
        connectionWatcher.onDisconnect = { [weak self] in
            Task { @MainActor in self?.status = .waitingForAirPods }
        }
        manager.delegate = connectionWatcher
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let sample = MotionSample(motion)
            MainActor.assumeIsolated { self?.receive(sample) }
        }
        status = .waitingForAirPods

        // The connect callback does not fire for AirPods that were already in
        // when the app started, and sometimes not on reconnect either. Readings
        // arriving (or stopping) is the one signal that never lies, so status
        // follows that.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func receive(_ sample: MotionSample) {
        lastReadingAt = Date()
        readingsSinceLastTick += 1
        if status != .streaming { status = .streaming }

        buffer.append(sample)
        if let newest = buffer.last?.timestamp, let firstKept = buffer.firstIndex(where: { newest - $0.timestamp <= graphSeconds }), firstKept > 0 {
            buffer.removeFirst(firstKept)
        }
        if readingsSinceLastTick % 3 == 0 { recentSamples = buffer }
        onSample?(sample)
    }

    private func tick() {
        readingsPerSecond = Double(readingsSinceLastTick)
        if status == .streaming { Self.log.debug("readings per second: \(self.readingsSinceLastTick, privacy: .public)") }
        readingsSinceLastTick = 0
        if CMHeadphoneMotionManager.authorizationStatus() == .denied {
            status = .permissionDenied
        } else if let lastReadingAt, Date().timeIntervalSince(lastReadingAt) > 1.5, status == .streaming {
            status = .waitingForAirPods
        }
    }
}

/// CoreMotion wants an NSObject delegate; the source itself stays a plain
/// observable class.
private final class ConnectionWatcher: NSObject, CMHeadphoneMotionManagerDelegate {
    var onDisconnect: (() -> Void)?

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        onDisconnect?()
    }
}

private extension MotionSample {
    init(_ motion: CMDeviceMotion) {
        self.init(
            timestamp: motion.timestamp,
            attitude: Vector3(x: motion.attitude.pitch, y: motion.attitude.roll, z: motion.attitude.yaw),
            rotationRate: Vector3(x: motion.rotationRate.x, y: motion.rotationRate.y, z: motion.rotationRate.z),
            userAcceleration: Vector3(x: motion.userAcceleration.x, y: motion.userAcceleration.y, z: motion.userAcceleration.z)
        )
    }
}
