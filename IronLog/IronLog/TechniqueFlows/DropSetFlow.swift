import Foundation

/// Drop set: working set -> drop (no rest, auto-reduce weight) -> rest -> repeat
struct DropSetFlow: TechniqueFlow {
    let exerciseIndex: Int
    var exerciseIndices: [Int] { [exerciseIndex] }
    var displayName: String? { "Drop set" }

    /// Fallback drop when the plan does not prescribe one.
    private static let defaultDropPercent = 0.3

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

        guard let nextSetIdx = ex.sets.firstIndex(where: { !$0.isCompleted }) else {
            return nil
        }

        let nextSet = ex.sets[nextSetIdx]
        let isFirstStep = completedExerciseIndex == nil

        if nextSet.type == "drop" {
            // Drop set: no rest, auto-reduce weight from last working set
            // `weight_percent_drop` is an unbounded number in the import
            // schema, so an author writing 30 instead of 0.3 would otherwise
            // collapse the drop to a locked 1 kg the user cannot correct.
            let rawPct = nextSet.prescribedWeightPercentDrop ?? Self.defaultDropPercent
            let pct = min(max(rawPct, 0.05), 0.9)
            let baseWeight = lastWorkingWeight(ex) ?? nextSet.weightKg ?? 0
            let dropWeight = baseWeight > 0
                ? max(1, (baseWeight * (1 - pct)).rounded())
                : nil
            let instruction = dropWeight.map { "Drop to \(Int($0)) kg -- no rest!" }
                ?? "Drop the weight -- no rest!"

            return TechniqueStep(
                exerciseIndex: exerciseIndex,
                setIndex: nextSetIdx,
                instruction: instruction,
                suggestedWeightKg: dropWeight,
                restSeconds: nil, // no rest before drop
                prescribedReps: nextSet.prescribedReps,
                isTerminal: nextSetIdx == ex.sets.count - 1,
                // Only lock a weight we could actually compute; otherwise the
                // user has to be able to dial it in.
                lockWeight: dropWeight != nil
            )
        } else {
            // Working set: rest after previous (unless first)
            let weight = lastWorkingWeight(ex) ?? nextSet.weightKg

            // Rest only if we just completed a drop set (end of a working+drop pair)
            let justFinishedDrop: Bool
            if let completedIdx = completedSetIndex {
                justFinishedDrop = ex.sets[completedIdx].type == "drop"
            } else {
                justFinishedDrop = false
            }

            let restSeconds: Int?
            if isFirstStep {
                restSeconds = nil
            } else if justFinishedDrop {
                restSeconds = ex.restSeconds
            } else {
                // This shouldn't normally happen (working after working in drop_set technique)
                restSeconds = ex.restSeconds
            }

            return TechniqueStep(
                exerciseIndex: exerciseIndex,
                setIndex: nextSetIdx,
                instruction: formatInstruction(
                    set: nextSet,
                    setNumber: nextSetIdx + 1,
                    totalSets: ex.sets.count
                ),
                suggestedWeightKg: weight,
                restSeconds: restSeconds,
                prescribedReps: nextSet.prescribedReps,
                isTerminal: nextSetIdx == ex.sets.count - 1
            )
        }
    }
}
