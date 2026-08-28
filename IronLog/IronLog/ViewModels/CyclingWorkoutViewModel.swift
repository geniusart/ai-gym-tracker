import Foundation
import SwiftData
import UIKit

// MARK: - Expanded execution step

/// One leaf segment in execution order. `path` is stable across runs of
/// the same template -- used in the log to match back to the plan.
struct CyclingExecStep: Identifiable {
    let id = UUID()
    let path: String         // "warmup", "block[0].rep[1].work", etc
    let kind: String         // warmup/work/recovery/cooldown/steady
    let name: String
    let durationSeconds: Int
    let targetType: String?
    let targetMin: Int?
    let targetMax: Int?
    let targetZoneLabel: String?
    let notes: String?

    var hasHrTarget: Bool {
        targetType == "hr_bpm_range" && targetMin != nil && targetMax != nil
    }

    var targetText: String {
        switch targetType {
        case "hr_bpm_range":
            let label = targetZoneLabel.map { " (\($0))" } ?? ""
            return "\(targetMin ?? 0)-\(targetMax ?? 0) bpm\(label)"
        case "rpe":
            return "RPE \(targetMin ?? 0)-\(targetMax ?? 0)"
        case "free":
            return "free"
        default:
            return ""
        }
    }
}

// MARK: - Expander + schedule generator

enum CyclingExpander {

    /// Flattens a template into the linear list of leaf steps that the
    /// executor walks through.
    static func expand(_ template: SDCyclingTemplate) -> [CyclingExecStep] {
        var result: [CyclingExecStep] = []
        let topLevel = template.segments.sorted { $0.sortOrder < $1.sortOrder }

        for (i, seg) in topLevel.enumerated() {
            if seg.kind == CyclingSegmentKind.intervalBlock.rawValue {
                let reps = seg.repeats ?? 1
                let children = seg.children.sorted { $0.sortOrder < $1.sortOrder }
                for r in 0..<reps {
                    for child in children {
                        result.append(makeStep(child, path: "block[\(i)].rep[\(r)].\(child.kind)"))
                    }
                }
            } else {
                result.append(makeStep(seg, path: "\(seg.kind)#\(i)"))
            }
        }
        return result
    }

    static func totalDuration(for template: SDCyclingTemplate) -> Int {
        expand(template).reduce(0) { $0 + $1.durationSeconds }
    }

    /// Pure function: given the workout's starting wall-clock moment and
    /// any accumulated pause / skip offsets, produce the absolute
    /// `endsAt` timestamps for every step.
    ///
    ///   endsAt[i] = startedAt + sum(durations 0..=i) + pausedTotal - skipCredit
    ///
    /// - `pausedTotal`: total wall-clock time the workout was paused
    ///   (shifts everything LATER -- we lost that real time).
    /// - `skipCredit`: total wall-clock time the user "skipped past" via
    ///   the Skip button (shifts everything EARLIER -- they want to
    ///   advance faster than real time would allow).
    static func makeSchedule(
        steps: [CyclingExecStep],
        startedAt: Date,
        pausedTotal: TimeInterval = 0,
        skipCredit: TimeInterval = 0
    ) -> [ScheduledSegment] {
        var cumulative: TimeInterval = 0
        return steps.enumerated().map { (i, step) in
            cumulative += TimeInterval(step.durationSeconds)
            let endsAt = startedAt
                .addingTimeInterval(cumulative)
                .addingTimeInterval(pausedTotal)
                .addingTimeInterval(-skipCredit)
            return ScheduledSegment(
                stepIndex: i,
                stepName: step.name,
                stepKind: step.kind,
                endsAt: endsAt
            )
        }
    }

    /// Pure function: walk the steps consuming `elapsed` seconds. Returns
    /// `(stepIndex, secondsElapsedInThatStep)`. If `elapsed` exceeds the
    /// total duration, `stepIndex == steps.count` (workout complete).
    static func locate(
        elapsed: TimeInterval,
        in steps: [CyclingExecStep]
    ) -> (stepIndex: Int, inStepSeconds: TimeInterval) {
        var remaining = elapsed
        for (i, step) in steps.enumerated() {
            let dur = TimeInterval(step.durationSeconds)
            if remaining < dur {
                return (i, max(0, remaining))
            }
            remaining -= dur
        }
        return (steps.count, 0)
    }

    private static func makeStep(_ s: SDCyclingSegment, path: String) -> CyclingExecStep {
        CyclingExecStep(
            path: path,
            kind: s.kind,
            name: s.name,
            durationSeconds: s.durationSeconds ?? 0,
            targetType: s.targetType,
            targetMin: s.targetMin,
            targetMax: s.targetMax,
            targetZoneLabel: s.targetZoneLabel,
            notes: s.notes
        )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class CyclingWorkoutViewModel {

    enum State: Equatable {
        case idle
        case running
        case paused
        case finishing
        case saved
    }

    var state: State = .idle
    var steps: [CyclingExecStep] = []
    /// Index of the currently-active step. Computed by `tick()` from the
    /// wall-clock elapsed since `workoutStartedAt`. SwiftUI re-renders
    /// when this changes so the in-app UI stays in lockstep with the
    /// Live Activity (which derives the same value from `Date.now`).
    var currentStepIndex: Int = 0
    /// Seconds elapsed in the current step. Same wall-clock source.
    var elapsedInStepSeconds: Int = 0
    /// Latest HR sample, polled from `hrSource` on each tick. Stored here
    /// so SwiftUI re-renders -- the underlying `HRSource` is not @Observable.
    var liveBpm: Int?
    /// Wall-clock moment of the most recent HR sample. Drives the
    /// "X seconds ago" freshness indicator in the executor view.
    var liveBpmSampleAt: Date?
    var hrSource: HRSource = NoHRSource()
    var persistenceErrorMessage: String?

    /// Per-step in-memory metrics; flushed to `SDCyclingSegmentLog` on save.
    private var stepMetrics: [Int: StepMetrics] = [:]

    private var workout: SDCyclingWorkout?
    private var modelContext: ModelContext?
    private var sourcePlan: SDCyclingPlan?
    private var sourceTemplate: SDCyclingTemplate?
    private var stateBeforeFinishing: State?

    // MARK: - Wall-clock state

    /// Wall-clock moment the workout was started. Source of truth.
    private var workoutStartedAt: Date?
    /// When `state == .paused`, the moment we entered the pause.
    private var pausedAt: Date?
    /// Total seconds the workout has been paused across all pauses so far
    /// (excluding the currently-active pause).
    private var pausedDurationTotal: TimeInterval = 0
    /// Total seconds the user has "skipped past" via the Skip button.
    /// Shifts the timeline forward without consuming real wall-clock time.
    private var skipCreditSeconds: TimeInterval = 0

    private struct StepMetrics {
        var actualDuration: Int = 0
        var hrSamples: [Int] = []
        var inZoneSeconds: Int = 0
        var skipped: Bool = false
    }

    // MARK: - Computed

    var currentStep: CyclingExecStep? {
        guard currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    var totalDurationSeconds: Int {
        steps.reduce(0) { $0 + $1.durationSeconds }
    }

    var elapsedTotalSeconds: Int {
        let priorSteps = steps.prefix(currentStepIndex)
            .reduce(0) { $0 + $1.durationSeconds }
        return priorSteps + elapsedInStepSeconds
    }

    var remainingInStep: Int {
        max(0, (currentStep?.durationSeconds ?? 0) - elapsedInStepSeconds)
    }

    /// Seconds after which a latched HR reading stops counting as live.
    /// Apple Health buffers and flushes in batches, so the window has to be
    /// wider than the watch's ~1 Hz push.
    private static let hrFreshnessWindow: TimeInterval = 15

    /// True if the last HR sample is recent enough to be treated as live.
    /// Every `HRSource` keeps its last value forever, so metrics have to
    /// check the timestamp rather than just the presence of a reading.
    var isHrFresh: Bool {
        guard let at = liveBpmSampleAt else { return false }
        return Date.now.timeIntervalSince(at) < Self.hrFreshnessWindow
    }

    /// True if the current HR sample is within the current step's target range.
    var isInZone: Bool? {
        guard let step = currentStep, step.hasHrTarget,
              let bpm = liveBpm,
              let lo = step.targetMin, let hi = step.targetMax else { return nil }
        return bpm >= lo && bpm <= hi
    }

    // MARK: - Lifecycle

    func startWorkout(
        plan: SDCyclingPlan,
        template: SDCyclingTemplate,
        context: ModelContext
    ) {
        modelContext = context
        sourcePlan = plan
        sourceTemplate = template

        steps = CyclingExpander.expand(template)
        currentStepIndex = 0
        elapsedInStepSeconds = 0
        stepMetrics = [:]
        for i in steps.indices { stepMetrics[i] = StepMetrics() }

        let now = Date.now
        workoutStartedAt = now
        pausedAt = nil
        pausedDurationTotal = 0
        skipCreditSeconds = 0

        let sd = SDCyclingWorkout(
            planId: plan.planId,
            planName: plan.planName,
            planVersion: plan.planVersion,
            templateId: template.templateId,
            templateName: template.name,
            startedAt: now
        )
        context.insert(sd)
        guard saveContext(context, action: "start cycling workout") else {
            context.delete(sd)
            state = .idle
            return
        }
        workout = sd

        hrSource = HRSourceResolver.resolve()
        hrSource.start()
        // Note: `WatchHRSource.start()` (legacy path requiring IronLogWatch)
        // talks to `WorkoutSessionManager` itself. `PhoneWorkoutHRSource`
        // (iOS 26+) and `HealthKitHRSource` don't need WatchConnectivity at
        // all -- so we don't poke `WorkoutSessionManager` externally here.
        // Doing so would log "WCSession counterpart app not installed"
        // every cycling start when IronLogWatch isn't present.

        state = .running

        // Pre-schedule notifications at every segment boundary so the
        // user gets alerted (banner + sound) even with the iPhone in
        // another app.
        CyclingNotificationScheduler.scheduleAll(
            steps: steps,
            fromIndex: 0,
            elapsedInCurrentStep: 0
        )

        // Live Activity gets the FULL schedule -- the widget self-advances
        // by comparing each `endsAt` to `Date.now`. No need for the host
        // app to push updates at every transition.
        let schedule = CyclingExpander.makeSchedule(
            steps: steps,
            startedAt: now
        )
        CyclingActivityManager.shared.start(
            workoutName: template.name,
            totalSteps: steps.count,
            schedule: schedule
        )
    }

    /// Resume an in-progress cycling workout after the app was killed
    /// or the user came back via a Live Activity tap. Reconstructs every
    /// derivable piece of state (current step, elapsed) from
    /// `sdWorkout.startedAt` via wall-clock arithmetic. Transient data
    /// (pause history, skip credits, in-memory HR samples) is lost --
    /// the trade-off for keeping LA / SwiftData as the only persistence.
    func resumeWorkout(
        plan: SDCyclingPlan,
        template: SDCyclingTemplate,
        sdWorkout: SDCyclingWorkout,
        context: ModelContext
    ) {
        // Re-entry guard: the picker calls this from `onAppear`, which also
        // fires when the user backs out of the finish screen. If this VM is
        // already running the same workout, everything below would wipe the
        // accumulated metrics (HR samples, pause and skip credit) that only
        // live in memory. Restore the executor instead of restarting it.
        if let current = workout,
           current.workoutId == sdWorkout.workoutId,
           state != .idle, state != .saved {
            if case .finishing = state {
                cancelFinishing()
            }
            return
        }

        modelContext = context
        sourcePlan = plan
        sourceTemplate = template
        workout = sdWorkout

        steps = CyclingExpander.expand(template)
        workoutStartedAt = sdWorkout.startedAt
        pausedAt = nil
        pausedDurationTotal = 0
        skipCreditSeconds = 0
        stepMetrics = [:]
        for i in steps.indices { stepMetrics[i] = StepMetrics() }

        let elapsed = Date.now.timeIntervalSince(sdWorkout.startedAt)
        let (idx, inStep) = CyclingExpander.locate(elapsed: elapsed, in: steps)

        if idx >= steps.count {
            // Wall-clock already past the end -- jump straight to finishing.
            currentStepIndex = steps.count
            elapsedInStepSeconds = 0
            beginFinishing()
            return
        }

        currentStepIndex = idx
        elapsedInStepSeconds = Int(inStep)
        state = .running

        hrSource = HRSourceResolver.resolve()
        hrSource.start()

        // Re-establish Live Activity + notifications. The original
        // schedule from start time is still valid -- we just push a fresh
        // copy in case the LA was dismissed.
        let schedule = CyclingExpander.makeSchedule(
            steps: steps,
            startedAt: sdWorkout.startedAt
        )
        CyclingActivityManager.shared.start(
            workoutName: template.name,
            totalSteps: steps.count,
            schedule: schedule
        )
        CyclingNotificationScheduler.scheduleAll(
            steps: steps,
            fromIndex: idx,
            elapsedInCurrentStep: Int(inStep)
        )
    }

    /// Called once per second by the view's timer when the app is in the
    /// foreground. Idempotent -- can also be called on `scenePhase`
    /// becoming active to catch up after a long background session.
    ///
    /// All state derives from wall-clock arithmetic; the tick is purely
    /// a refresh trigger for SwiftUI.
    func tick() {
        liveBpm = hrSource.currentBpm
        liveBpmSampleAt = hrSource.lastSampleAt

        guard state == .running else { return }

        let elapsed = realElapsedSinceStart()
        let (newIdx, inStepSec) = CyclingExpander.locate(
            elapsed: elapsed, in: steps
        )

        if newIdx >= steps.count {
            // Workout complete: clamp state and transition to finishing.
            // Mark any unfinished steps as completed in metrics.
            for i in currentStepIndex..<steps.count {
                var m = stepMetrics[i] ?? StepMetrics()
                if !m.skipped {
                    m.actualDuration = steps[i].durationSeconds
                }
                stepMetrics[i] = m
            }
            currentStepIndex = steps.count
            elapsedInStepSeconds = 0
            beginFinishing()
            return
        }

        // Detect step transition (possibly skipping multiple in one tick
        // if the app was backgrounded long enough to miss boundaries).
        if newIdx > currentStepIndex {
            for i in currentStepIndex..<newIdx {
                var m = stepMetrics[i] ?? StepMetrics()
                if !m.skipped {
                    m.actualDuration = steps[i].durationSeconds
                }
                stepMetrics[i] = m
            }
            currentStepIndex = newIdx
            // The Live Activity does not re-evaluate its own body when a
            // segment ends, so the banner would keep showing the previous
            // segment's name and icon. Push the schedule again, which also
            // re-arms `staleDate` for the next boundary.
            pushScheduleToWidget()
            // One haptic for the latest crossed boundary -- don't burst
            // multiple if app caught up after a long background.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        elapsedInStepSeconds = Int(inStepSec)

        // Live HR sampling (foreground-only -- background ticks don't run).
        var metrics = stepMetrics[currentStepIndex] ?? StepMetrics()
        metrics.actualDuration = elapsedInStepSeconds
        // Only count a reading the source actually refreshed recently. Every
        // HRSource latches its last value, so without this a watch taken off
        // mid-ride would keep scoring in-zone seconds until the end.
        if let bpm = liveBpm, isHrFresh {
            metrics.hrSamples.append(bpm)
            if let inZone = isInZone, inZone {
                metrics.inZoneSeconds += 1
            }
        }
        stepMetrics[currentStepIndex] = metrics
    }

    func togglePause() {
        switch state {
        case .running:
            state = .paused
            pausedAt = Date.now
            CyclingNotificationScheduler.cancelAll()
            CyclingActivityManager.shared.setPaused(true)
        case .paused:
            if let pa = pausedAt {
                pausedDurationTotal += Date.now.timeIntervalSince(pa)
            }
            pausedAt = nil
            state = .running
            // Push a fresh schedule with the new `pausedDurationTotal`
            // so the LA's `endsAt` values reflect the lost time.
            pushScheduleToWidget()
            CyclingNotificationScheduler.scheduleAll(
                steps: steps,
                fromIndex: currentStepIndex,
                elapsedInCurrentStep: elapsedInStepSeconds
            )
        default:
            break
        }
    }

    /// Skip the current step. Marks it as skipped in metrics; adds the
    /// remaining duration to `skipCreditSeconds` so the timeline jumps
    /// forward.
    func skipStep() {
        // `tick()` ignores everything while paused, so skipping there would
        // bank credit without moving the timeline and would silently re-arm
        // the notifications and Live Activity that `togglePause` cancelled.
        guard state == .running else { return }
        guard currentStepIndex < steps.count else { return }
        var metrics = stepMetrics[currentStepIndex] ?? StepMetrics()
        metrics.skipped = true
        stepMetrics[currentStepIndex] = metrics

        let stepDuration = TimeInterval(steps[currentStepIndex].durationSeconds)
        let remaining = max(0, stepDuration - TimeInterval(elapsedInStepSeconds))
        skipCreditSeconds += remaining

        // Foreground haptic for the user's deliberate action.
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Recompute current step from new elapsed.
        tick()

        // Push the new schedule (everything shifts earlier by `remaining`).
        pushScheduleToWidget()
        CyclingNotificationScheduler.scheduleAll(
            steps: steps,
            fromIndex: currentStepIndex,
            elapsedInCurrentStep: elapsedInStepSeconds
        )
    }

    func beginFinishing() {
        if case .finishing = state {
            return
        }
        stateBeforeFinishing = state
        state = .finishing
        CyclingNotificationScheduler.cancelAll()
        CyclingActivityManager.shared.end()
        // `WatchHRSource.stop()` ends the IronLogWatch session itself when
        // that path is active. We don't poke `WorkoutSessionManager` here.
    }

    /// False once the timeline is exhausted: there is nothing left to resume,
    /// so the finish form must not offer the button at all.
    var canCancelFinishing: Bool {
        currentStepIndex < steps.count
    }

    func cancelFinishing() {
        guard canCancelFinishing else { return }
        state = stateBeforeFinishing ?? .running
        if state == .running {
            tick()
        }
        restoreCyclingActivityAfterFinishing()
        stateBeforeFinishing = nil
    }

    func saveWorkout(notes: String?, perceivedEffort: Int?) {
        guard let workout, let context = modelContext else { return }

        hrSource.stop()

        let endDate = Date.now
        workout.finishedAt = endDate
        workout.totalDurationSeconds = stepMetrics.values.reduce(0) { $0 + $1.actualDuration }
        workout.workoutNotes = (notes?.isEmpty == false) ? notes : nil
        workout.perceivedEffort = perceivedEffort

        let allSamples = stepMetrics.values.flatMap(\.hrSamples)
        let hadHr = !allSamples.isEmpty
        workout.hadHrSource = hadHr
        if hadHr {
            workout.averageHr = Int(allSamples.reduce(0, +) / max(1, allSamples.count))
            workout.maxHr = allSamples.max()
        }

        for (idx, step) in steps.enumerated() {
            let metrics = stepMetrics[idx] ?? StepMetrics()
            let log = SDCyclingSegmentLog(
                segmentPath: step.path,
                sortOrder: idx,
                kind: step.kind,
                name: step.name,
                durationSecondsActual: metrics.actualDuration,
                targetMinBpm: step.hasHrTarget ? step.targetMin : nil,
                targetMaxBpm: step.hasHrTarget ? step.targetMax : nil,
                averageHr: metrics.hrSamples.isEmpty ? nil : Int(metrics.hrSamples.reduce(0, +) / max(1, metrics.hrSamples.count)),
                maxHr: metrics.hrSamples.max(),
                inZoneSeconds: metrics.hrSamples.isEmpty ? nil : metrics.inZoneSeconds,
                skipped: metrics.skipped
            )
            log.workout = workout
        }

        guard saveContext(context, action: "save cycling workout") else { return }

        if SyncService.isConfigured,
           SyncService.isAuthenticated,
           workout.syncedAt == nil {
            Task { @MainActor in
                await WorkoutSyncService.uploadCycling(
                    workout,
                    context: context,
                    force: true
                )
            }
        }

        stateBeforeFinishing = nil
        state = .saved
    }

    @discardableResult
    private func saveContext(
        _ context: ModelContext,
        action: String
    ) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            persistenceErrorMessage = "Could not \(action): \(error.localizedDescription)"
            return false
        }
    }

    func reset() {
        hrSource.stop()
        hrSource = NoHRSource()
        liveBpm = nil
        liveBpmSampleAt = nil
        persistenceErrorMessage = nil
        state = .idle
        steps = []
        currentStepIndex = 0
        elapsedInStepSeconds = 0
        stepMetrics = [:]
        workout = nil
        modelContext = nil
        sourcePlan = nil
        sourceTemplate = nil
        stateBeforeFinishing = nil
        workoutStartedAt = nil
        pausedAt = nil
        pausedDurationTotal = 0
        skipCreditSeconds = 0
        CyclingNotificationScheduler.cancelAll()
        CyclingActivityManager.shared.end()
    }

    // MARK: - Wall-clock helpers

    /// Wall-clock seconds since `workoutStartedAt`, minus accumulated pause
    /// time, plus skip credit. The fundamental "where am I in the workout"
    /// metric -- everything else (current step, elapsed-in-step, schedule)
    /// is derived from this.
    private func realElapsedSinceStart() -> TimeInterval {
        guard let started = workoutStartedAt else { return 0 }
        let raw = Date.now.timeIntervalSince(started)
        let pausedNow = pausedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        return max(0, raw - pausedDurationTotal - pausedNow + skipCreditSeconds)
    }

    /// Push a fresh schedule (with current pause/skip offsets) to the LA.
    private func pushScheduleToWidget() {
        guard let started = workoutStartedAt else { return }
        let schedule = CyclingExpander.makeSchedule(
            steps: steps,
            startedAt: started,
            pausedTotal: pausedDurationTotal,
            skipCredit: skipCreditSeconds
        )
        CyclingActivityManager.shared.updateSchedule(
            schedule,
            paused: state == .paused
        )
    }

    private func restoreCyclingActivityAfterFinishing() {
        guard let started = workoutStartedAt else { return }
        let schedule = CyclingExpander.makeSchedule(
            steps: steps,
            startedAt: started,
            pausedTotal: pausedDurationTotal,
            skipCredit: skipCreditSeconds
        )
        CyclingActivityManager.shared.start(
            workoutName: sourceTemplate?.name ?? workout?.templateName ?? "Cycling",
            totalSteps: steps.count,
            schedule: schedule
        )

        switch state {
        case .running:
            CyclingNotificationScheduler.scheduleAll(
                steps: steps,
                fromIndex: currentStepIndex,
                elapsedInCurrentStep: elapsedInStepSeconds
            )
        case .paused:
            CyclingActivityManager.shared.setPaused(true)
        default:
            break
        }
    }
}
