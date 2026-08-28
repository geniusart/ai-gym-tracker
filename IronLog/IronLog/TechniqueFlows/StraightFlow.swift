import Foundation

/// Normal sequential sets with rest between each.
struct StraightFlow: TechniqueFlow {
    let exerciseIndex: Int
    var exerciseIndices: [Int] { [exerciseIndex] }

    func nextStep(
        exercises: [ExerciseState],
        completedExerciseIndex: Int?,
        completedSetIndex: Int?,
        completedReps: Int?
    ) -> TechniqueStep? {
        // `TechniqueFlowFactory` falls back to a flow even when it could not
        // validate the index, so every flow bounds-checks before subscripting.
        guard exercises.indices.contains(exerciseIndex) else {
            assertionFailure("Invalid exerciseIndex \(exerciseIndex) for exercises count \(exercises.count)")
            return nil
        }
        let ex = exercises[exerciseIndex]

        // Find first incomplete set
        guard let nextSetIdx = ex.sets.firstIndex(where: { !$0.isCompleted }) else {
            return nil // all done
        }

        // Weight: last completed weight for this exercise, or prescribed, or nil
        let weight = lastWorkingWeight(ex) ?? ex.sets[nextSetIdx].weightKg

        // Rest: after completing a set, rest before next. No rest before the very first set.
        let needsRest = completedExerciseIndex != nil && completedSetIndex != nil
        let restSeconds = needsRest ? ex.restSeconds : nil

        return TechniqueStep(
            exerciseIndex: exerciseIndex,
            setIndex: nextSetIdx,
            instruction: "",
            suggestedWeightKg: weight,
            restSeconds: restSeconds,
            prescribedReps: ex.sets[nextSetIdx].prescribedReps,
            isTerminal: nextSetIdx == ex.sets.count - 1
        )
    }
}

// MARK: - Helpers

func lastWorkingWeight(_ ex: ExerciseState) -> Double? {
    ex.sets
        .filter { $0.isCompleted && $0.type != "drop" && $0.type != "myo_mini" && $0.type != "warmup" }
        .compactMap(\.weightKg)
        .last
}

func lastCompletedWeightAny(_ ex: ExerciseState) -> Double? {
    ex.sets
        .filter { $0.isCompleted }
        .compactMap(\.weightKg)
        .last
}

func formatInstruction(
    set: SetState,
    setNumber: Int,
    totalSets: Int
) -> String {
    var parts: [String] = []
    if let reps = set.prescribedReps {
        parts.append("\(reps) reps")
    }
    if let rir = set.prescribedRir {
        parts.append("RIR \(rir)")
    }
    return parts.isEmpty ? "Set \(setNumber) of \(totalSets)" : parts.joined(separator: ", ")
}
