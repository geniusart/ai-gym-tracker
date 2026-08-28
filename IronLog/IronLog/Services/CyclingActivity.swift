import ActivityKit
import Foundation
import SwiftUI

// MARK: - Schedule entry

/// One segment in the workout's pre-computed timeline. The Live Activity
/// payload carries the full list so the widget can pick the "current" segment
/// by comparing `endsAt` to `Date.now`.
///
/// Note: carrying the full schedule is NOT enough on its own. `Text(timerInterval:)`
/// is a self-updating leaf that the system ticks from an already-rendered view --
/// it does not re-run the `ActivityConfiguration` content closure, so the segment
/// name, icon and "Step X of N" stay frozen at whatever `Date.now` was when the
/// content was last pushed. The host therefore pushes an update at each segment
/// transition, and sets `staleDate` to the current segment's end so the system
/// re-renders at the boundary even when the app is not running.
public struct ScheduledSegment: Codable, Hashable, Identifiable {
    public let stepIndex: Int       // 0-based position in the workout
    public let stepName: String     // display name (Russian, from plan)
    public let stepKind: String     // warmup | work | recovery | cooldown | steady
    public let endsAt: Date         // absolute wall-clock end-time

    public var id: Int { stepIndex }
}

// MARK: - Activity Attributes

/// Live Activity payload for a cycling workout.
///
/// We ship the **entire workout schedule** (every segment's absolute end-time)
/// in the content state, not just the current segment, so that any re-render --
/// a screen wake, a Dynamic Island expand, a `staleDate` refresh, or a push from
/// the host -- lands on the right segment without needing fresh data. It is the
/// re-render that has to be arranged; see `ScheduledSegment`.
struct CyclingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Full timeline. The widget picks `current` as
        /// `first(where: $0.endsAt > Date.now)`.
        var schedule: [ScheduledSegment]

        /// When `true` the widget freezes the countdown and shows
        /// "Paused". On resume the host pushes a NEW schedule with all
        /// `endsAt` shifted forward by the paused duration, so the
        /// widget rejoins seamlessly.
        var paused: Bool
    }

    /// Static across the workout.
    let totalSteps: Int
    let workoutName: String
}

// MARK: - Activity Manager

/// Singleton wrapping ActivityKit lifecycle for a cycling Live Activity.
@MainActor
final class CyclingActivityManager {

    static let shared = CyclingActivityManager()
    private var currentActivity: Activity<CyclingActivityAttributes>?

    private init() {}

    /// Start the Live Activity with the given full schedule.
    /// Idempotent: if an activity is already running it pushes an update
    /// instead of requesting a new one.
    func start(
        workoutName: String,
        totalSteps: Int,
        schedule: [ScheduledSegment]
    ) {
        let state = CyclingActivityAttributes.ContentState(
            schedule: schedule,
            paused: false
        )
        let stale = Self.staleDate(for: schedule)
        if let activity = currentActivity {
            Task { await activity.update(.init(state: state, staleDate: stale)) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = CyclingActivityAttributes(
                totalSteps: totalSteps,
                workoutName: workoutName
            )
            do {
                currentActivity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: stale),
                    pushType: nil
                )
            } catch {
                // ActivityKit may refuse if user disabled Live Activities;
                // workout continues without it.
            }
        }
    }

    /// Push a freshly computed schedule. Called on pause/resume/skip and at
    /// every segment transition -- the banner cannot advance on its own.
    func updateSchedule(_ schedule: [ScheduledSegment], paused: Bool = false) {
        guard let activity = currentActivity else { return }
        let state = CyclingActivityAttributes.ContentState(
            schedule: schedule,
            paused: paused
        )
        let stale = paused ? nil : Self.staleDate(for: schedule)
        Task { await activity.update(.init(state: state, staleDate: stale)) }
    }

    /// Flip the paused flag. The schedule is left as-is until resume,
    /// at which point the caller should push a shifted schedule via
    /// `updateSchedule`.
    func setPaused(_ paused: Bool) {
        guard let activity = currentActivity else { return }
        let prev = activity.content.state
        let state = CyclingActivityAttributes.ContentState(
            schedule: prev.schedule,
            paused: paused
        )
        let stale = paused ? nil : Self.staleDate(for: prev.schedule)
        Task { await activity.update(.init(state: state, staleDate: stale)) }
    }

    /// The moment the pushed content stops being accurate: the end of the
    /// segment that is current right now. ActivityKit re-renders the activity
    /// then, which is the only chance a suspended app has to move the banner
    /// on to the next segment.
    private static func staleDate(for schedule: [ScheduledSegment]) -> Date? {
        let now = Date.now
        return schedule.first(where: { $0.endsAt > now })?.endsAt
    }

    func end() {
        let activityToEnd = currentActivity
        let currentId = activityToEnd?.id
        let lingeringActivities = Activity<CyclingActivityAttributes>.activities
        Task {
            if let activityToEnd {
                await activityToEnd.end(nil, dismissalPolicy: .immediate)
            }
            for activity in lingeringActivities where activity.id != currentId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        currentActivity = nil
    }
}
