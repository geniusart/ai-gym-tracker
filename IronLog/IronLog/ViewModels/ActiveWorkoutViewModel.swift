import Foundation
import SwiftData

// MARK: - State types

struct SetState: Identifiable {
    let id = UUID()
    var setNumber: Int
    var type: String
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    var rir: Int?
    var isCompleted: Bool = false
    var failed: Bool = false
    var setDurationSeconds: Int?

    // Prescribed hints
    var prescribedReps: Int?
    var prescribedWeightKg: Double?
    var prescribedRir: Int?
    var prescribedWeightPercentDrop: Double?
}

struct ExerciseState: Identifiable {
    let id = UUID()
    let exerciseId: String
    let catalogId: String?
    let name: String
    let bodyPart: String
    let equipment: String?
    let technique: String
    let supersetWith: String?
    let restSeconds: Int
    let tempo: String?
    let notes: String?
    let stretchFocus: Bool
    let maxMiniSets: Int?
    var sets: [SetState]
    var supersetPartnerIndex: Int? = nil
}

// MARK: - Phases within a set

enum SetPhase: Equatable {
    case ready          // before set: shows weight preview + Start
    case performing     // during set: timer + weight/reps adjustable + Done
    case resting        // countdown, auto-transitions to next step
}

// MARK: - ViewModel

@MainActor
@Observable
final class ActiveWorkoutViewModel {

    enum State: Equatable {
        case idle
        case active
        case loggingSet(exerciseIndex: Int, setIndex: Int)
        case restTimer
        case finishing
        case saved
    }

    // MARK: - Properties

    var state: State = .idle
    var exercises: [ExerciseState] = []
    var currentExerciseIndex: Int = 0
    var currentSetIndex: Int = 0
    var setPhase: SetPhase = .ready
    var restTimer = RestTimerService()
    var setStopwatch = StopwatchService()
    var finishNotes: String = ""
    var finishEffort: Int?
    var skipHealthKit = false
    var persistenceErrorMessage: String?

    /// Current technique flow driving the workout progression
    private(set) var currentFlow: (any TechniqueFlow)?

    /// Instruction text from the current technique flow
    var flowInstruction: String = ""
    /// Whether the current step locks weight (drop/myo mini)
    var flowLockWeight: Bool = false

    private(set) var workout: SDWorkout?
    private var modelContext: ModelContext?
    private var lastSetCompletedAt: Date?
    private var lastCompletedSetLog: SDSetLog?
    private var historicalTemplateDurationSeconds: Int?
    private var stateBeforeFinishing: State?
    private var pendingRatingExerciseIndex: Int?
    private var autoStartSetAfterRest = false

    // MARK: - Computed

    var currentExercise: ExerciseState? {
        guard exercises.indices.contains(currentExerciseIndex) else { return nil }
        return exercises[currentExerciseIndex]
    }

    var currentSet: SetState? {
        guard let ex = currentExercise,
              currentSetIndex < ex.sets.count else { return nil }
        return ex.sets[currentSetIndex]
    }

    var lastCompletedWeight: Double? {
        weightForExercise(at: currentExerciseIndex)
    }

    /// Weight for a specific exercise: last working weight, or prescribed, or nil
    func weightForExercise(at exerciseIdx: Int) -> Double? {
        guard exercises.indices.contains(exerciseIdx) else { return nil }
        let ex = exercises[exerciseIdx]
        // 1. Last completed working weight (not from drop sets)
        if let w = lastWorkingWeight(ex) { return w }
        // 2. Any completed weight
        if let w = lastCompletedWeightAny(ex) { return w }
        // 3. Current set's pre-filled weight
        guard !ex.sets.isEmpty else { return nil }
        let setIdx: Int
        if exerciseIdx == currentExerciseIndex,
           ex.sets.indices.contains(currentSetIndex) {
            setIdx = currentSetIndex
        } else {
            setIdx = ex.sets.firstIndex { !$0.isCompleted } ?? 0
        }
        if let w = ex.sets[setIdx].weightKg { return w }
        // 4. Prescribed weight from plan
        if let pw = ex.sets[setIdx].prescribedWeightKg {
            return pw
        }
        return nil
    }

    var completedSetsCount: Int {
        exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count }
    }

    var totalSetsCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    var completedExercisesCount: Int {
        exercises.filter { ex in ex.sets.allSatisfy(\.isCompleted) }.count
    }

    var isDynamicFlow: Bool {
        currentFlow?.supportsDynamicSets ?? false
    }

    /// True when resting before advancing to the next exercise (not next set)
    var isRestBeforeNextExercise: Bool {
        pendingAdvanceToNextExercise
    }

    /// True for short technique pauses where tapping the timer should enter
    /// the next set directly instead of showing a separate Start button.
    var restStartsNextSetImmediately: Bool {
        autoStartSetAfterRest && !pendingAdvanceToNextExercise
    }

    /// Name of the next exercise (if any), following the same walk the
    /// executor uses so a superset pair is not announced twice.
    var nextExerciseName: String? {
        guard let nextIdx = nextExerciseIndexAfterCurrentFlow() else { return nil }
        return exercises[nextIdx].name
    }

    var remainingWorkoutMinutesText: String? {
        guard let seconds = estimatedRemainingWorkoutSeconds,
              seconds > 0
        else { return nil }

        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "~\(minutes) min left"
    }

    // MARK: - Start Workout

    func startWorkout(
        template: SDTemplate,
        context: ModelContext
    ) {
        modelContext = context

        let sdWorkout = SDWorkout(
            templateId: template.templateId,
            templateName: template.name,
            planType: template.plan?.planType,
            planId: template.plan?.planId,
            planName: template.plan?.planName,
            planVersion: template.plan?.planVersion
        )
        context.insert(sdWorkout)
        guard saveContext(context, action: "start workout") else {
            context.delete(sdWorkout)
            return
        }
        workout = sdWorkout

        buildExercises(from: template, loggedSets: [:])
        linkSupersetPartners()
        refreshHistoricalTimeBaseline(
            templateId: template.templateId,
            excludingWorkoutId: sdWorkout.workoutId,
            context: context
        )
        currentExerciseIndex = 0
        currentSetIndex = 0
        setPhase = .ready
        state = .active
        activateFlowForCurrentExercise()

        // Mirror to Apple Watch
        WorkoutSessionManager.shared.startMirroring()
    }

    // MARK: - Resume Workout

    func resumeWorkout(
        sdWorkout: SDWorkout,
        template: SDTemplate,
        context: ModelContext
    ) {
        modelContext = context
        workout = sdWorkout

        let loggedSets = Dictionary(
            grouping: sdWorkout.exercises.flatMap { exLog in
                exLog.sets.map { (exLog.exerciseId, $0) }
            },
            by: \.0
        ).mapValues { $0.map(\.1) }

        buildExercises(from: template, loggedSets: loggedSets)
        linkSupersetPartners()
        refreshHistoricalTimeBaseline(
            templateId: template.templateId,
            excludingWorkoutId: sdWorkout.workoutId,
            context: context
        )

        // Find first incomplete exercise/set
        for (eIdx, ex) in exercises.enumerated() {
            if let sIdx = ex.sets.firstIndex(where: { !$0.isCompleted }) {
                currentExerciseIndex = eIdx
                currentSetIndex = sIdx
                setPhase = .ready
                state = .active
                activateFlowForCurrentExercise()
                return
            }
        }

        // All sets done
        currentExerciseIndex = exercises.count - 1
        currentSetIndex = 0
        state = .active
        beginFinishing()
    }

    private func buildExercises(
        from template: SDTemplate,
        loggedSets: [String: [SDSetLog]]
    ) {
        let sortedGroups = template.groups.sorted { $0.sortOrder < $1.sortOrder }
        exercises = sortedGroups.flatMap { group in
            group.exercises
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { exercise in
                    let sortedSets = exercise.prescribedSets
                        .sorted { $0.sortOrder < $1.sortOrder }
                    let logged = loggedSets[exercise.exerciseId] ?? []

                    let setStates = sortedSets.enumerated().map { idx, ps in
                        let matchingLog = logged.first { $0.setNumber == idx + 1 }
                        return SetState(
                            setNumber: idx + 1,
                            type: ps.type,
                            weightKg: matchingLog?.weightKg ?? ps.weightKg,
                            reps: matchingLog?.reps,
                            isCompleted: matchingLog != nil,
                            failed: matchingLog?.failed ?? false,
                            prescribedReps: ps.reps,
                            prescribedWeightKg: ps.weightKg,
                            prescribedRir: ps.rir,
                            prescribedWeightPercentDrop: ps.weightPercentDrop
                        )
                    }
                    return ExerciseState(
                        exerciseId: exercise.exerciseId,
                        catalogId: exercise.catalogId,
                        name: exercise.name,
                        bodyPart: exercise.bodyPart,
                        equipment: exercise.equipment,
                        technique: exercise.technique,
                        supersetWith: exercise.supersetWith,
                        restSeconds: exercise.restSeconds,
                        tempo: exercise.tempo,
                        notes: exercise.notes,
                        stretchFocus: exercise.stretchFocus,
                        maxMiniSets: exercise.maxMiniSets,
                        sets: setStates
                    )
                }
        }
    }

    private func linkSupersetPartners() {
        for i in exercises.indices {
            if let partnerId = exercises[i].supersetWith,
               let partnerIdx = exercises.firstIndex(where: { $0.exerciseId == partnerId }) {
                exercises[i].supersetPartnerIndex = partnerIdx
            }
        }
    }

    // MARK: - Flow Management

    /// Creates and activates the TechniqueFlow for the current exercise.
    private func activateFlowForCurrentExercise() {
        currentFlow = TechniqueFlowFactory.makeFlow(
            for: currentExerciseIndex,
            exercises: exercises
        )
        updateFlowInstruction(
            completedExerciseIndex: nil,
            completedSetIndex: nil,
            completedReps: nil
        )
    }

    private func updateFlowInstruction(
        completedExerciseIndex: Int?,
        completedSetIndex: Int?,
        completedReps: Int?
    ) {
        if let step = currentFlow?.nextStep(
            exercises: exercises,
            completedExerciseIndex: completedExerciseIndex,
            completedSetIndex: completedSetIndex,
            completedReps: completedReps
        ) {
            flowInstruction = step.instruction
            flowLockWeight = step.lockWeight
            // Apply suggested weight if the set has no weight yet
            if let w = step.suggestedWeightKg,
               exercises.indices.contains(step.exerciseIndex),
               exercises[step.exerciseIndex].sets.indices.contains(step.setIndex),
               exercises[step.exerciseIndex].sets[step.setIndex].weightKg == nil {
                exercises[step.exerciseIndex].sets[step.setIndex].weightKg = w
            }
        }
    }

    // MARK: - Set Flow

    // Ready phase: slide right = start set with current weight
    func readySlideRight() {
        guard exercises.indices.contains(currentExerciseIndex),
              exercises[currentExerciseIndex].sets.indices.contains(currentSetIndex)
        else { return }

        let set = exercises[currentExerciseIndex].sets[currentSetIndex]
        // Only apply last weight if this set has no prescribed weight
        if set.weightKg == nil, let last = lastCompletedWeight {
            exercises[currentExerciseIndex].sets[currentSetIndex].weightKg = last
        }
        beginPerforming()
    }

    private func beginPerforming() {
        guard exercises.indices.contains(currentExerciseIndex),
              exercises[currentExerciseIndex].sets.indices.contains(currentSetIndex)
        else { return }

        // Record actual rest duration on previous set
        if let completedAt = lastSetCompletedAt {
            let actualRest = Int(Date().timeIntervalSince(completedAt))
            persistRestDuration(actualRest)
        }

        setPhase = .performing
        setStopwatch.start()
        state = .loggingSet(
            exerciseIndex: currentExerciseIndex,
            setIndex: currentSetIndex
        )

        // Update Live Activity to performing phase
        RestTimerActivityManager.shared.startPerforming(
            exerciseName: currentExercise?.name ?? "",
            weightKg: exercises[currentExerciseIndex].sets[currentSetIndex].weightKg
        )
    }

    // Performing phase: confirm weight + reps and finish set
    func confirmPerforming(weight: Double, reps: Int) {
        guard exercises.indices.contains(currentExerciseIndex),
              exercises[currentExerciseIndex].sets.indices.contains(currentSetIndex)
        else { return }

        setStopwatch.stop()
        exercises[currentExerciseIndex].sets[currentSetIndex].weightKg = weight
        completeCurrentSet(reps: reps)
    }

    // MARK: - Core: Complete Set + Flow-Driven Progression

    private func completeCurrentSet(reps: Int) {
        guard exercises.indices.contains(currentExerciseIndex),
              exercises[currentExerciseIndex].sets.indices.contains(currentSetIndex)
        else { return }

        // Mark set as completed
        exercises[currentExerciseIndex].sets[currentSetIndex].reps = reps
        exercises[currentExerciseIndex].sets[currentSetIndex].isCompleted = true
        exercises[currentExerciseIndex].sets[currentSetIndex].setDurationSeconds =
            setStopwatch.elapsedSeconds

        lastSetCompletedAt = Date()
        persistCompletedSet()

        let completedExIdx = currentExerciseIndex
        let completedSetIdx = currentSetIndex

        // Ask flow for next step
        guard let flow = currentFlow else {
            autoStartSetAfterRest = false
            startRest(seconds: exercises[currentExerciseIndex].restSeconds)
            return
        }

        guard let nextStep = flow.nextStep(
            exercises: exercises,
            completedExerciseIndex: completedExIdx,
            completedSetIndex: completedSetIdx,
            completedReps: reps
        ) else {
            // Flow complete -- rest then advance to next exercise
            flowInstruction = ""
            flowLockWeight = false
            let restSeconds = exercises[completedExIdx].restSeconds
            pendingAdvanceToNextExercise = true
            autoStartSetAfterRest = false
            pendingRatingExerciseIndex = completedExIdx
            startRest(seconds: restSeconds)
            return
        }

        // Dynamic set insertion (myo-reps mini-sets)
        guard exercises.indices.contains(nextStep.exerciseIndex) else { return }

        if flow.supportsDynamicSets
            && nextStep.setIndex >= exercises[nextStep.exerciseIndex].sets.count {
            let newSet = SetState(
                setNumber: nextStep.setIndex + 1,
                type: "myo_mini",
                prescribedReps: nextStep.prescribedReps,
                prescribedRir: nil,
                prescribedWeightPercentDrop: nil
            )
            exercises[nextStep.exerciseIndex].sets.append(newSet)
        }

        guard exercises[nextStep.exerciseIndex].sets.indices.contains(nextStep.setIndex) else {
            return
        }

        // Apply suggested weight
        if let w = nextStep.suggestedWeightKg {
            exercises[nextStep.exerciseIndex].sets[nextStep.setIndex].weightKg = w
        }

        // Update current position
        currentExerciseIndex = nextStep.exerciseIndex
        currentSetIndex = nextStep.setIndex
        flowInstruction = nextStep.instruction
        flowLockWeight = nextStep.lockWeight

        // Rest or go directly
        if let rest = nextStep.restSeconds, rest > 0 {
            pendingAdvanceToNextExercise = false
            autoStartSetAfterRest = shouldAutoStartAfterRest(
                flow: flow,
                nextStep: nextStep
            )
            startRest(seconds: rest)
        } else {
            autoStartSetAfterRest = false
            setPhase = .ready
            state = .active
        }
    }

    /// Flag: after rest finishes, should we advance to next exercise?
    private var pendingAdvanceToNextExercise = false

    private func startRest(seconds: Int) {
        if seconds > 0 {
            setPhase = .resting
            state = .restTimer

            // Provide context for Live Activity
            restTimer.liveActivityExerciseName = currentExercise?.name ?? ""
            restTimer.liveActivityNextLabel = flowInstruction.isEmpty
                ? "SET \(currentSetIndex + 1)"
                : flowInstruction

            restTimer.start(seconds: seconds)
        } else {
            onRestComplete()
        }
    }

    func skipRest() {
        // The Live Activity stays up: `onRestComplete` either pushes the
        // performing phase or ends it, so tearing it down here would only
        // cause an extra teardown/request round trip.
        restTimer.stopTicking()
        onRestComplete()
    }

    func onRestFinished() {
        restTimer.stopTicking()
        onRestComplete()
    }

    private func onRestComplete() {
        if pendingAdvanceToNextExercise {
            pendingAdvanceToNextExercise = false
            autoStartSetAfterRest = false
            applyPendingRatingAndAdvance()
            endRestActivityIfIdle()
        } else if autoStartSetAfterRest {
            autoStartSetAfterRest = false
            // Pushes the performing phase onto the same Live Activity.
            beginPerforming()
        } else {
            // Flow already set currentExerciseIndex/currentSetIndex
            setPhase = .ready
            state = .active
            endRestActivityIfIdle()
        }
    }

    /// The rest countdown no longer reflects anything, and nothing is about to
    /// push a new phase, so retire the Live Activity rather than leaving a
    /// stale banner on the Lock Screen.
    private func endRestActivityIfIdle() {
        guard setPhase != .performing else { return }
        RestTimerActivityManager.shared.endIfNeeded()
    }

    func finishExercise() {
        // Trigger rest-before-next-exercise so the user can rate during rest
        pendingAdvanceToNextExercise = true
        autoStartSetAfterRest = false
        pendingRatingExerciseIndex = currentExerciseIndex
        let restSeconds = currentExercise?.restSeconds ?? 60
        startRest(seconds: restSeconds)
    }

    /// Pending rating set by the user during rest. Applied on rest completion.
    var pendingRating: Int?

    /// User taps Heavy/OK/Easy during rest. Toggles off if same value pressed again.
    func setPendingRating(_ rating: Int?) {
        if pendingRating == rating {
            pendingRating = nil
        } else {
            pendingRating = rating
        }
    }

    /// Write a rating the user tapped during the between-exercise rest onto
    /// the exercise it was tapped for. Every path that leaves that rest --
    /// advancing, jumping elsewhere, finishing -- has to call this, or the
    /// rating is either dropped or applied to the wrong exercise.
    private func applyPendingRating() {
        defer {
            pendingRating = nil
            pendingRatingExerciseIndex = nil
        }
        let ratingIndex = pendingRatingExerciseIndex ?? currentExerciseIndex
        guard let rating = pendingRating,
              let workout,
              exercises.indices.contains(ratingIndex)
        else { return }
        let exId = exercises[ratingIndex].exerciseId
        guard let exLog = workout.exercises.first(where: { $0.exerciseId == exId })
        else { return }
        exLog.exerciseRating = rating
        if let context = modelContext {
            _ = saveContext(context, action: "save exercise rating")
        }
    }

    private func applyPendingRatingAndAdvance() {
        applyPendingRating()
        advanceToNextExercise()
    }

    private func advanceToNextExercise() {
        guard !exercises.isEmpty else {
            beginFinishing()
            return
        }

        // Find next exercise not covered by the current flow, skipping the
        // junior superset partners the flow already ran.
        if let nextIdx = nextExerciseIndexAfterCurrentFlow() {
            currentExerciseIndex = nextIdx
            currentSetIndex = 0
            activateFlowForCurrentExercise()

            // Apply initial weight from flow
            if let step = currentFlow?.nextStep(
                exercises: exercises,
                completedExerciseIndex: nil,
                completedSetIndex: nil,
                completedReps: nil
            ),
               exercises.indices.contains(step.exerciseIndex),
               exercises[step.exerciseIndex].sets.indices.contains(step.setIndex) {
                currentExerciseIndex = step.exerciseIndex
                currentSetIndex = step.setIndex
                if let w = step.suggestedWeightKg {
                    exercises[step.exerciseIndex].sets[step.setIndex].weightKg = w
                }
                flowInstruction = step.instruction
            }

            setPhase = .ready
            state = .active
        } else {
            beginFinishing()
        }
    }

    // MARK: - Navigation (skip/jump)

    func jumpToExercise(_ index: Int) {
        guard exercises.indices.contains(index) else { return }
        restTimer.stop()
        setStopwatch.stop()
        pendingAdvanceToNextExercise = false
        autoStartSetAfterRest = false
        // The rating bar belongs to the exercise the user just finished;
        // jumping away must not carry it over to a different one.
        applyPendingRating()
        currentExerciseIndex = index
        let sets = exercises[index].sets
        currentSetIndex = sets.firstIndex(where: { !$0.isCompleted }) ?? 0
        activateFlowForCurrentExercise()
        setPhase = .ready
        state = .active
    }

    func skipExercise() {
        advanceToNextExercise()
    }

    // MARK: - Time Estimate

    private enum TimeEstimate {
        static let liveProjectionStartProgress = 0.25
        static let liveProjectionBlendSpan = 0.50
        static let maxLiveProjectionWeight = 0.60
        static let minLiveOnlyElapsedSeconds = 10 * 60
        static let dropOrMyoMiniUnits = 0.35
        static let warmupUnits = 0.75
    }

    private struct TimeEstimateProgress {
        let remainingUnits: Double
        let completedFraction: Double
    }

    private var estimatedRemainingWorkoutSeconds: Int? {
        guard let workout,
              let progress = timeEstimateProgress,
              progress.remainingUnits > 0
        else { return nil }

        let elapsedSeconds = max(
            0,
            Int(Date.now.timeIntervalSince(workout.startedAt))
        )

        if let historicalSeconds = historicalTemplateDurationSeconds {
            return historicallyAnchoredRemainingSeconds(
                elapsedSeconds: elapsedSeconds,
                historicalSeconds: historicalSeconds,
                completedFraction: progress.completedFraction
            )
        }

        return liveOnlyRemainingSeconds(
            elapsedSeconds: elapsedSeconds,
            completedFraction: progress.completedFraction
        )
    }

    private func historicallyAnchoredRemainingSeconds(
        elapsedSeconds: Int,
        historicalSeconds: Int,
        completedFraction: Double
    ) -> Int {
        let anchoredRemaining = max(historicalSeconds - elapsedSeconds, 0)
        guard completedFraction >= TimeEstimate.liveProjectionStartProgress else {
            return anchoredRemaining
        }

        let projectedTotal = projectedTotalSeconds(
            elapsedSeconds: elapsedSeconds,
            completedFraction: completedFraction
        )
        let liveWeight = liveProjectionWeight(for: completedFraction)
        let blendedTotal = Int(
            (Double(historicalSeconds) * (1 - liveWeight)
             + Double(projectedTotal) * liveWeight).rounded()
        )
        return max(blendedTotal - elapsedSeconds, 0)
    }

    private func liveOnlyRemainingSeconds(
        elapsedSeconds: Int,
        completedFraction: Double
    ) -> Int? {
        guard completedFraction >= TimeEstimate.liveProjectionStartProgress,
              elapsedSeconds >= TimeEstimate.minLiveOnlyElapsedSeconds
        else {
            return nil
        }

        let projectedTotal = projectedTotalSeconds(
            elapsedSeconds: elapsedSeconds,
            completedFraction: completedFraction
        )
        return max(projectedTotal - elapsedSeconds, 0)
    }

    private func projectedTotalSeconds(
        elapsedSeconds: Int,
        completedFraction: Double
    ) -> Int {
        Int((Double(elapsedSeconds) / completedFraction).rounded())
    }

    private func liveProjectionWeight(for completedFraction: Double) -> Double {
        let progressPastStart = completedFraction
            - TimeEstimate.liveProjectionStartProgress
        let rawWeight = progressPastStart / TimeEstimate.liveProjectionBlendSpan
        return min(TimeEstimate.maxLiveProjectionWeight, rawWeight)
    }

    private var timeEstimateProgress: TimeEstimateProgress? {
        let total = totalEstimateUnits
        guard total > 0,
              let remaining = remainingSetUnitsForEstimate
        else { return nil }

        let completedFraction = min(max((total - remaining) / total, 0), 0.95)
        return TimeEstimateProgress(
            remainingUnits: remaining,
            completedFraction: completedFraction
        )
    }

    private var remainingSetUnitsForEstimate: Double? {
        guard !exercises.isEmpty else { return nil }

        guard let startIndex = estimateStartExerciseIndex else {
            return 0
        }
        guard exercises.indices.contains(startIndex) else { return nil }

        return exercises[startIndex...].reduce(0.0) { total, exercise in
            total + remainingEstimateUnits(for: exercise)
        }
    }

    private var estimateStartExerciseIndex: Int? {
        if pendingAdvanceToNextExercise {
            return nextExerciseIndexAfterCurrentFlow()
        }
        return currentFlow?.exerciseIndices.min() ?? currentExerciseIndex
    }

    private var totalEstimateUnits: Double {
        exercises.reduce(0.0) { sum, exercise in
            sum + totalEstimateUnits(for: exercise)
        }
    }

    private func totalEstimateUnits(for exercise: ExerciseState) -> Double {
        exercise.sets.map(estimateUnits).reduce(0, +)
            + uncreatedMyoMiniSetUnits(for: exercise)
    }

    private func remainingEstimateUnits(for exercise: ExerciseState) -> Double {
        exercise.sets
            .filter { !$0.isCompleted }
            .map(estimateUnits)
            .reduce(0, +)
            + uncreatedMyoMiniSetUnits(for: exercise)
    }

    private func estimateUnits(for set: SetState) -> Double {
        switch set.type {
        case "drop", "myo_mini":
            return TimeEstimate.dropOrMyoMiniUnits
        case "warmup":
            return TimeEstimate.warmupUnits
        default:
            return 1.0
        }
    }

    private func uncreatedMyoMiniSetUnits(
        for exercise: ExerciseState
    ) -> Double {
        guard exercise.technique == "myo_reps",
              let maxMiniSets = exercise.maxMiniSets
        else { return 0 }

        let completedMiniSets = exercise.sets.filter {
            $0.type == "myo_mini" && $0.isCompleted
        }.count
        let pendingMiniSets = exercise.sets.filter {
            $0.type == "myo_mini" && !$0.isCompleted
        }.count

        return Double(max(0, maxMiniSets - completedMiniSets - pendingMiniSets))
            * TimeEstimate.dropOrMyoMiniUnits
    }

    func nextExerciseIndexAfterCurrentFlow() -> Int? {
        let coveredIndices = Set(currentFlow?.exerciseIndices ?? [])
        var nextIdx = (coveredIndices.max() ?? currentExerciseIndex) + 1

        while exercises.indices.contains(nextIdx) {
            let exercise = exercises[nextIdx]
            if exercise.technique == "superset",
               let partnerIdx = exercise.supersetPartnerIndex,
               partnerIdx < nextIdx {
                nextIdx += 1
            } else {
                break
            }
        }

        return exercises.indices.contains(nextIdx) ? nextIdx : nil
    }

    private func refreshHistoricalTimeBaseline(
        templateId: String,
        excludingWorkoutId: String,
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor<SDWorkout>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )

        let workouts = (try? context.fetch(descriptor)) ?? []
        let durations = workouts
            .lazy
            .filter { workout in
                workout.templateId == templateId
                    && workout.workoutId != excludingWorkoutId
                    && workout.finishedAt != nil
                    && workout.durationMinutes != nil
            }
            .prefix(5)
            .compactMap { workout -> Int? in
                guard let durationMinutes = workout.durationMinutes,
                      durationMinutes > 0
                else { return nil }
                return Int((durationMinutes * 60.0).rounded())
            }

        historicalTemplateDurationSeconds = median(Array(durations))
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count.isMultiple(of: 2) {
            return Int((Double(sorted[middle - 1]) + Double(sorted[middle])) / 2.0)
        }
        return sorted[middle]
    }

    private func shouldAutoStartAfterRest(
        flow: any TechniqueFlow,
        nextStep: TechniqueStep
    ) -> Bool {
        guard exercises.indices.contains(nextStep.exerciseIndex),
              exercises[nextStep.exerciseIndex].sets.indices.contains(nextStep.setIndex)
        else { return false }

        let nextSet = exercises[nextStep.exerciseIndex].sets[nextStep.setIndex]
        if flow is MyoRepsFlow {
            return nextSet.type == "myo_mini"
        }
        if flow is StraightFlow {
            return true
        }
        return false
    }

    // MARK: - Exercise Notes

    func saveExerciseNote(
        _ note: String,
        forExerciseAt index: Int
    ) {
        guard let workout,
              let context = modelContext,
              exercises.indices.contains(index)
        else { return }

        let exState = exercises[index]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if let exLog = workout.exercises.first(where: {
            $0.exerciseId == exState.exerciseId
        }) {
            applyExerciseMetadata(to: exLog, from: exState, order: index)
            exLog.exerciseNotes = trimmed.isEmpty ? nil : trimmed
        } else {
            let newLog = SDExerciseLog(
                exerciseId: exState.exerciseId,
                catalogId: exState.catalogId,
                exerciseName: exState.name,
                bodyPart: exState.bodyPart,
                order: index,
                technique: exState.technique,
                supersetWith: exState.supersetWith,
                exerciseNotes: trimmed.isEmpty ? nil : trimmed
            )
            newLog.workout = workout
        }
        _ = saveContext(context, action: "save exercise note")
    }

    func exerciseNote(at index: Int) -> String {
        guard let workout,
              exercises.indices.contains(index)
        else { return "" }

        let exId = exercises[index].exerciseId
        return workout.exercises
            .first { $0.exerciseId == exId }?
            .exerciseNotes ?? ""
    }

    // MARK: - Finish

    func beginFinishing() {
        if case .finishing = state {
            return
        }
        stateBeforeFinishing = state
        state = .finishing
    }

    func cancelFinishing() {
        state = stateBeforeFinishing ?? .active
        stateBeforeFinishing = nil
    }

    // MARK: - Incremental Persistence

    private func persistCompletedSet() {
        guard let workout,
              let context = modelContext,
              exercises.indices.contains(currentExerciseIndex),
              exercises[currentExerciseIndex].sets.indices.contains(currentSetIndex)
        else { return }

        let exState = exercises[currentExerciseIndex]
        let setState = exState.sets[currentSetIndex]

        let exerciseLog: SDExerciseLog
        if let existing = workout.exercises.first(where: {
            $0.exerciseId == exState.exerciseId
        }) {
            exerciseLog = existing
            applyExerciseMetadata(
                to: exerciseLog,
                from: exState,
                order: currentExerciseIndex
            )
        } else {
            let newLog = SDExerciseLog(
                exerciseId: exState.exerciseId,
                catalogId: exState.catalogId,
                exerciseName: exState.name,
                bodyPart: exState.bodyPart,
                order: currentExerciseIndex,
                technique: exState.technique,
                supersetWith: exState.supersetWith
            )
            newLog.workout = workout
            exerciseLog = newLog
        }

        let completedAt = lastSetCompletedAt ?? Date()
        let oldSet = exerciseLog.sets.first {
            $0.setNumber == setState.setNumber
        }
        let sequenceIndex = oldSet?.sequenceIndex
            ?? nextSetSequenceIndex(in: workout)
        let preservedRestSecondsAfter = oldSet?.restSecondsAfter

        if let oldSet = exerciseLog.sets.first(where: {
            $0.setNumber == setState.setNumber
        }) {
            context.delete(oldSet)
        }

        let setLog = SDSetLog(
            setNumber: setState.setNumber,
            setType: setState.type,
            weightKg: setState.weightKg,
            reps: setState.reps,
            rpe: setState.rpe,
            rir: setState.rir,
            completedAt: oldSet?.completedAt ?? completedAt,
            sequenceIndex: sequenceIndex,
            restSecondsAfter: preservedRestSecondsAfter,
            setDurationSeconds: setState.setDurationSeconds,
            isPr: false,
            failed: setState.failed
        )
        setLog.exerciseLog = exerciseLog
        lastCompletedSetLog = setLog

        _ = saveContext(context, action: "save completed set")
    }

    private func persistRestDuration(_ seconds: Int) {
        guard let workout,
              let context = modelContext
        else { return }

        var target = lastCompletedSetLog
        if target?.exerciseLog?.workout !== workout {
            target = latestCompletedSetLog(in: workout)
        }
        guard let target, !target.isDeleted else { return }
        target.restSecondsAfter = seconds
        _ = saveContext(context, action: "save rest duration")
    }

    private func applyExerciseMetadata(
        to exerciseLog: SDExerciseLog,
        from exerciseState: ExerciseState,
        order: Int
    ) {
        exerciseLog.catalogId = exerciseState.catalogId
        exerciseLog.exerciseName = exerciseState.name
        exerciseLog.bodyPart = exerciseState.bodyPart
        exerciseLog.order = order
        exerciseLog.technique = exerciseState.technique
        exerciseLog.supersetWith = exerciseState.supersetWith
    }

    private func nextSetSequenceIndex(in workout: SDWorkout) -> Int {
        let existingSequences = workout.exercises
            .flatMap(\.sets)
            .compactMap(\.sequenceIndex)

        if let maxSequence = existingSequences.max() {
            return maxSequence + 1
        }
        return workout.exercises.flatMap(\.sets).count + 1
    }

    private func latestCompletedSetLog(in workout: SDWorkout) -> SDSetLog? {
        workout.exercises
            .flatMap(\.sets)
            .max(by: isChronologicallyBefore)
    }

    private func isChronologicallyBefore(
        _ lhs: SDSetLog,
        _ rhs: SDSetLog
    ) -> Bool {
        if let lhsSequence = lhs.sequenceIndex,
           let rhsSequence = rhs.sequenceIndex,
           lhsSequence != rhsSequence {
            return lhsSequence < rhsSequence
        }
        if lhs.sequenceIndex != nil {
            return true
        }
        if rhs.sequenceIndex != nil {
            return false
        }
        if let lhsCompletedAt = lhs.completedAt,
           let rhsCompletedAt = rhs.completedAt,
           lhsCompletedAt != rhsCompletedAt {
            return lhsCompletedAt < rhsCompletedAt
        }
        return lhs.setNumber < rhs.setNumber
    }

    func saveWorkout() {
        guard let workout, let context = modelContext else { return }

        applyPendingRating()

        let endDate = Date.now
        workout.finishedAt = endDate
        workout.durationMinutes = endDate.timeIntervalSince(workout.startedAt) / 60
        workout.workoutNotes = finishNotes.isEmpty ? nil : finishNotes
        workout.perceivedEffort = finishEffort

        guard saveContext(context, action: "save workout") else { return }

        restTimer.stop()
        setStopwatch.stop()

        // Stop Apple Watch mirroring
        WorkoutSessionManager.shared.stopMirroring()

        // Save to HealthKit
        if !skipHealthKit {
            let totalVolume = workout.exercises.flatMap(\.sets).reduce(0.0) { sum, set in
                let w = set.weightKg ?? 0
                let r = Double(set.reps ?? 0)
                return sum + w * r
            }
            let totalSets = workout.exercises.flatMap(\.sets).count

            HealthKitManager.shared.saveWorkout(
                startDate: workout.startedAt,
                endDate: endDate,
                totalVolume: totalVolume,
                totalSets: totalSets,
                templateName: workout.templateName,
                planName: workout.planName
            )
        }

        // Upload log to sync server (fire-and-forget)
        if SyncService.isConfigured,
           SyncService.isAuthenticated,
           workout.syncedAt == nil {
            Task { @MainActor in
                await WorkoutSyncService.uploadStrength(
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
        state = .idle
        exercises = []
        workout = nil
        modelContext = nil
        currentExerciseIndex = 0
        currentSetIndex = 0
        setPhase = .ready
        finishNotes = ""
        finishEffort = nil
        persistenceErrorMessage = nil
        stateBeforeFinishing = nil
        currentFlow = nil
        flowInstruction = ""
        flowLockWeight = false
        pendingAdvanceToNextExercise = false
        autoStartSetAfterRest = false
        pendingRating = nil
        pendingRatingExerciseIndex = nil
        // These cache the previously completed set so the next one can record
        // how long the rest actually lasted. They point into the workout being
        // torn down, so keeping them would make the first set of the next
        // workout write a rest duration onto this one's last set.
        lastSetCompletedAt = nil
        lastCompletedSetLog = nil
        restTimer.stop()
        setStopwatch.stop()
        WorkoutSessionManager.shared.stopMirroring()
    }
}
