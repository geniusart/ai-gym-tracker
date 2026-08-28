import Foundation
import WatchConnectivity

/// Listener for live HR samples streamed from the Apple Watch during a
/// cardio workout. Implemented by `WatchHRSource`.
@MainActor
protocol HRSampleListener: AnyObject {
    func didReceiveHRSample(bpm: Int, at: Date)
}

/// Sends start/stop workout commands to Apple Watch via WatchConnectivity
/// and receives in-flight events back (e.g. live heart-rate samples during
/// a cycling workout). Single shared instance is the global WCSession
/// delegate.
@MainActor
final class WorkoutSessionManager: NSObject, ObservableObject {

    static let shared = WorkoutSessionManager()

    @Published var isMirroring = false

    private var wcSession: WCSession?
    private weak var hrListener: HRSampleListener?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
    }

    // MARK: - Reachability

    /// True iff a paired Watch with the IronLog app installed is currently
    /// activated. Reachability (`isReachable`) is a tighter check, but for
    /// "should we even try to source HR from the Watch?" this is enough --
    /// the executor falls back to no-HR if no samples arrive.
    var isWatchAvailable: Bool {
        guard let s = wcSession else { return false }
        return s.activationState == .activated
            && s.isPaired
            && s.isWatchAppInstalled
    }

    // MARK: - Strength (existing API)

    func startMirroring() {
        sendStartCommand(activity: "strength")
    }

    func stopMirroring() {
        isMirroring = false
        guard let session = wcSession else { return }

        // The watch implements only `session(_:didReceiveMessage:replyHandler:)`,
        // so the message has to carry a reply handler to be delivered at all --
        // the same shape `sendStartCommand` uses.
        if session.isReachable {
            session.sendMessage(
                ["command": "stopWorkout"],
                replyHandler: { _ in },
                errorHandler: { _ in
                    Task { @MainActor in
                        self.queueStopCommand()
                    }
                }
            )
        } else {
            // Out of range: queue it so the watch still ends its HKWorkoutSession
            // when the pair reconnects, instead of collecting HR forever.
            queueStopCommand()
        }
    }

    private func queueStopCommand() {
        guard let session = wcSession else { return }
        session.transferUserInfo(["command": "stopWorkout"])
    }

    // MARK: - Cardio (Phase 2)

    func startMirroringCardio() {
        sendStartCommand(activity: "cycling")
    }

    func registerHRListener(_ listener: HRSampleListener) {
        hrListener = listener
    }

    func unregisterHRListener(_ listener: HRSampleListener) {
        if hrListener === listener {
            hrListener = nil
        }
    }

    // MARK: - Private

    private func sendStartCommand(activity: String) {
        guard let session = wcSession, session.isReachable else { return }
        session.sendMessage(
            ["command": "startWorkout", "activity": activity],
            replyHandler: { _ in
                Task { @MainActor in
                    self.isMirroring = true
                }
            },
            errorHandler: { _ in
                // Watch not reachable -- ignore silently
            }
        )
    }
}

// MARK: - WCSessionDelegate

extension WorkoutSessionManager: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Watch posts events here: HR samples during cardio, etc.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let event = message["event"] as? String else { return }
        switch event {
        case "hr_sample":
            guard let bpm = message["bpm"] as? Int else { return }
            let ts: Date = {
                if let t = message["t"] as? TimeInterval {
                    return Date(timeIntervalSince1970: t)
                }
                return Date()
            }()
            Task { @MainActor in
                self.hrListener?.didReceiveHRSample(bpm: bpm, at: ts)
            }
        default:
            break
        }
    }
}
