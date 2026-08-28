import Foundation

enum WorkoutExportService {

    // MARK: - Cycling

    /// Top-level JSON envelope ready for ShareLink / clipboard copy.
    /// Mirrors `exportJSON` for strength: same envelope shape, just
    /// cycling-flavoured payload inside `workouts[]`.
    static func exportCyclingJSON(_ workout: SDCyclingWorkout) -> String {
        let envelope = CyclingLogEnvelopeJSON(
            version: "1.0",
            exportedAt: .now,
            workouts: [cyclingWorkoutToJSON(workout)]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(envelope),
              let str = String(data: data, encoding: .utf8)
        else {
            return "{ \"error\": \"encoding failed\" }"
        }
        return str
    }

    static func cyclingWorkoutToJSON(_ w: SDCyclingWorkout) -> CyclingWorkoutJSON {
        let segs = w.segments
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { s in
                CyclingSegmentLogJSON(
                    segmentPath: s.segmentPath,
                    kind: s.kind,
                    name: s.name,
                    durationSecondsActual: s.durationSecondsActual,
                    targetMinBpm: s.targetMinBpm,
                    targetMaxBpm: s.targetMaxBpm,
                    averageHr: s.averageHr,
                    maxHr: s.maxHr,
                    inZoneSeconds: s.inZoneSeconds,
                    inZonePct: s.inZonePct,
                    skipped: s.skipped
                )
            }

        return CyclingWorkoutJSON(
            id: w.workoutId,
            planType: w.planType,
            planId: w.planId,
            planName: w.planName,
            planVersion: w.planVersion,
            templateId: w.templateId,
            templateName: w.templateName,
            startedAt: w.startedAt,
            finishedAt: w.finishedAt,
            totalDurationSeconds: w.totalDurationSeconds,
            hadHrSource: w.hadHrSource,
            averageHr: w.averageHr,
            maxHr: w.maxHr,
            calories: w.calories,
            workoutNotes: w.workoutNotes,
            perceivedEffort: w.perceivedEffort,
            segments: segs
        )
    }

    // MARK: - Strength

    static func exportJSON(_ workout: SDWorkout) -> String {
        let log = WorkoutLogJSON(
            version: "1.0",
            exportedAt: .now,
            exportRange: nil,
            userProfile: nil,
            workouts: [workoutToJSON(workout)]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(log),
              let str = String(data: data, encoding: .utf8)
        else {
            return "{ \"error\": \"encoding failed\" }"
        }
        return str
    }

    static func workoutToJSON(_ w: SDWorkout) -> WorkoutJSON {
        let sortedExercises = w.exercises
            .sorted { $0.order < $1.order }

        let exerciseLogs = sortedExercises
            .map { ex in
                ExerciseLogJSON(
                    exerciseId: ex.exerciseId,
                    catalogId: ex.catalogId,
                    exerciseName: ex.exerciseName,
                    bodyPart: ex.bodyPart,
                    order: ex.order,
                    technique: ex.technique,
                    supersetWith: ex.supersetWith,
                    supersetPairId: supersetPairId(for: ex),
                    sets: ex.sets
                        .sorted { $0.setNumber < $1.setNumber }
                        .map { s in
                            setLogJSON(from: s)
                        },
                    exerciseNotes: ex.exerciseNotes,
                    exerciseRating: ex.exerciseRating
                )
            }

        let setEvents = chronologicalSetEvents(from: sortedExercises)

        return WorkoutJSON(
            id: w.workoutId,
            templateId: w.templateId,
            templateName: w.templateName,
            // Never omit it: the server's analytics all filter on
            // `plan_type == "strength"`, so a log without it is silently
            // excluded from volume, progression and workout counts. Rows
            // predating the field migrate in as nil.
            planType: w.planType.flatMap(PlanType.init(rawValue:)) ?? .strength,
            planId: w.planId,
            planName: w.planName,
            planVersion: w.planVersion,
            startedAt: w.startedAt,
            finishedAt: w.finishedAt,
            durationMinutes: w.durationMinutes,
            workoutNotes: w.workoutNotes,
            perceivedEffort: w.perceivedEffort,
            exercises: exerciseLogs,
            setEvents: setEvents.isEmpty ? nil : setEvents
        )
    }

    private static func setLogJSON(from s: SDSetLog) -> SetLogJSON {
        SetLogJSON(
            setNumber: s.setNumber,
            setType: LogSetType(rawValue: s.setType),
            weightKg: s.weightKg,
            reps: s.reps,
            rpe: s.rpe,
            rir: s.rir,
            completedAt: s.completedAt,
            sequenceIndex: s.sequenceIndex,
            restSecondsAfter: s.restSecondsAfter,
            setDurationSeconds: s.setDurationSeconds,
            isPr: s.isPr ? true : nil,
            failed: s.failed ? true : nil,
            notes: s.notes
        )
    }

    private static func chronologicalSetEvents(
        from exercises: [SDExerciseLog]
    ) -> [SetEventLogJSON] {
        let performedSets = exercises.flatMap { exercise in
            exercise.sets.map { set in (exercise, set) }
        }

        return performedSets
            .sorted(by: isChronologicallyBefore)
            .map { pair in
                let exercise = pair.0
                let set = pair.1
                return SetEventLogJSON(
                    sequenceIndex: set.sequenceIndex,
                    completedAt: set.completedAt,
                    exerciseId: exercise.exerciseId,
                    catalogId: exercise.catalogId,
                    exerciseName: exercise.exerciseName,
                    exerciseOrder: exercise.order,
                    technique: exercise.technique,
                    supersetPairId: supersetPairId(for: exercise),
                    supersetPartnerExerciseId: supersetPartnerExerciseId(for: exercise),
                    supersetPosition: supersetPosition(for: exercise),
                    supersetRound: supersetRound(for: exercise, set: set),
                    setNumber: set.setNumber,
                    setType: LogSetType(rawValue: set.setType),
                    weightKg: set.weightKg,
                    reps: set.reps,
                    rpe: set.rpe,
                    rir: set.rir,
                    restSecondsAfter: set.restSecondsAfter,
                    setDurationSeconds: set.setDurationSeconds,
                    isPr: set.isPr ? true : nil,
                    failed: set.failed ? true : nil,
                    notes: set.notes
                )
            }
    }

    private static func isChronologicallyBefore(
        _ lhs: (SDExerciseLog, SDSetLog),
        _ rhs: (SDExerciseLog, SDSetLog)
    ) -> Bool {
        if let lhsSequence = lhs.1.sequenceIndex,
           let rhsSequence = rhs.1.sequenceIndex,
           lhsSequence != rhsSequence {
            return lhsSequence < rhsSequence
        }
        if lhs.1.sequenceIndex != nil {
            return true
        }
        if rhs.1.sequenceIndex != nil {
            return false
        }

        if let lhsCompletedAt = lhs.1.completedAt,
           let rhsCompletedAt = rhs.1.completedAt,
           lhsCompletedAt != rhsCompletedAt {
            return lhsCompletedAt < rhsCompletedAt
        }
        if lhs.0.order != rhs.0.order {
            return lhs.0.order < rhs.0.order
        }
        return lhs.1.setNumber < rhs.1.setNumber
    }

    private static func supersetPairId(for exercise: SDExerciseLog) -> String? {
        guard exercise.technique == "superset",
              let partnerId = exercise.supersetWith,
              !partnerId.isEmpty
        else { return nil }

        return [exercise.exerciseId, partnerId]
            .sorted()
            .joined(separator: "+")
    }

    private static func supersetPartnerExerciseId(
        for exercise: SDExerciseLog
    ) -> String? {
        guard exercise.technique == "superset" else { return nil }
        return exercise.supersetWith
    }

    private static func supersetPosition(for exercise: SDExerciseLog) -> String? {
        guard exercise.technique == "superset",
              let partnerId = exercise.supersetWith
        else { return nil }

        return exercise.exerciseId < partnerId ? "first" : "second"
    }

    private static func supersetRound(
        for exercise: SDExerciseLog,
        set: SDSetLog
    ) -> Int? {
        exercise.technique == "superset" ? set.setNumber : nil
    }
}
