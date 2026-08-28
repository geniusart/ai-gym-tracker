import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
@Observable
final class RestTimerService {
    var secondsRemaining: Int = 0
    var totalSeconds: Int = 0
    var isRunning: Bool = false
    var overtimeSeconds: Int = 0
    var isOvertime: Bool = false
    private var didVibrate: Bool = false

    private var timerCancellable: AnyCancellable?
    private var startDate: Date?
    private static let notificationID = "rest-timer-done"

    /// Context for the Live Activity display
    var liveActivityExerciseName: String = ""
    var liveActivityNextLabel: String = ""

    func start(seconds: Int) {
        guard seconds > 0 else {
            stop()
            secondsRemaining = 0
            totalSeconds = 0
            overtimeSeconds = 0
            isOvertime = false
            return
        }
        // Only halt the ticker: `stop()` would end the Live Activity that the
        // `startResting` call below is about to replace, so every set would
        // tear the banner down and request a fresh one -- a visible flicker,
        // and eventually an ActivityKit start-budget failure mid-workout.
        stopTicking()
        totalSeconds = seconds
        secondsRemaining = seconds
        overtimeSeconds = 0
        isOvertime = false
        didVibrate = false
        isRunning = true
        startDate = .now

        scheduleNotification(seconds: seconds)
        RestTimerActivityManager.shared.startResting(
            exerciseName: liveActivityExerciseName,
            nextSetLabel: liveActivityNextLabel,
            totalSeconds: seconds
        )

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard let startDate else { return }
        let elapsed = Int(Date.now.timeIntervalSince(startDate))

        if elapsed < totalSeconds {
            secondsRemaining = totalSeconds - elapsed
            isOvertime = false
            overtimeSeconds = 0
        } else {
            secondsRemaining = 0
            overtimeSeconds = elapsed - totalSeconds
            if !isOvertime {
                enterOvertime()
            }
            isOvertime = true
        }
    }

    /// Stop the countdown without touching the Live Activity. Used when the
    /// caller immediately pushes a new phase to the same activity.
    func stopTicking() {
        timerCancellable?.cancel()
        timerCancellable = nil
        isRunning = false
        startDate = nil
        Self.cancelPendingNotification()
    }

    func stop() {
        stopTicking()
        RestTimerActivityManager.shared.endIfNeeded()
    }

    func skip() {
        stop()
        secondsRemaining = 0
    }

    /// Total actual rest in seconds (prescribed + overtime)
    var actualRestSeconds: Int {
        guard let startDate else { return totalSeconds }
        return Int(Date.now.timeIntervalSince(startDate))
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        if isOvertime { return 1.0 }
        return Double(totalSeconds - secondsRemaining) / Double(totalSeconds)
    }

    var formattedTime: String {
        if isOvertime {
            let m = overtimeSeconds / 60
            let s = overtimeSeconds % 60
            return String(format: "+%d:%02d", m, s)
        }
        let m = secondsRemaining / 60
        let s = secondsRemaining % 60
        return String(format: "%d:%02d", m, s)
    }

    private func enterOvertime() {
        if !didVibrate {
            didVibrate = true
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            RestTimerActivityManager.shared.markOvertime()
        }
    }

    // MARK: - Local Notifications (for locked screen)

    private func scheduleNotification(seconds: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = "Time for the next set!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(seconds),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    static func cancelPendingNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(
                withIdentifiers: [Self.notificationID]
            )
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(
                withIdentifiers: [Self.notificationID]
            )
    }

    /// Call once at app start to allow notifications
    static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}

// MARK: - Stopwatch (counts up, for set duration)

@MainActor
@Observable
final class StopwatchService {
    var elapsedSeconds: Int = 0
    var isRunning: Bool = false

    private var timerCancellable: AnyCancellable?
    private var startDate: Date?

    func start() {
        stop()
        elapsedSeconds = 0
        isRunning = true
        startDate = .now

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let start = self.startDate else { return }
                self.elapsedSeconds = Int(Date.now.timeIntervalSince(start))
            }
    }

    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
        isRunning = false
    }

    var formattedTime: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
