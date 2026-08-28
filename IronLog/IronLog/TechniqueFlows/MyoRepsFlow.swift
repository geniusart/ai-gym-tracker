import Foundation

/// Myo-reps: activation set -> 5s -> mini-set (3-5 reps) -> 5s -> ... -> finish
/// Stops when: user does < 3 reps, or max mini-sets reached.
struct MyoRepsFlow: TechniqueFlow {
    let exerciseIndex: Int
    let maxMiniSets: Int

    var exerciseIndices: [Int] { [exerciseIndex] }
    var displayName: String? { "Myo-reps" }
    var supportsDynamicSets: Bool { true }

    /// Short pause between mini-sets
    private let miniRestSeconds = 5
    /// Reps per mini-set
    private let miniSetReps = 5

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

        let completedCount = ex.sets.filter(\.isCompleted).count
        let miniSetsCompleted = max(0, completedCount - 1) // minus activation

        // Stop: user did fewer than 3 reps on last mini-set
        if completedCount > 1, let reps = completedReps, reps < 3 {
            return nil
        }

        // Stop: reached max mini-sets
        if miniSetsCompleted >= maxMiniSets {
            return nil
        }

        // Find first incomplete set
        if let nextSetIdx = ex.sets.firstIndex(where: { !$0.isCompleted }) {
            let nextSet = ex.sets[nextSetIdx]
            let weight = lastWorkingWeight(ex) ?? nextSet.weightKg
            let isActivation = completedCount == 0

            if isActivation {
                return TechniqueStep(
                    exerciseIndex: exerciseIndex,
                    setIndex: nextSetIdx,
                    instruction: "Activation: \(nextSet.prescribedReps ?? 15) reps, RIR 1-2",
                    suggestedWeightKg: weight,
                    restSeconds: nil,
                    prescribedReps: nextSet.prescribedReps,
                    isTerminal: false
                )
            } else {
                return TechniqueStep(
                    exerciseIndex: exerciseIndex,
                    setIndex: nextSetIdx,
                    instruction: "Mini-set \(miniSetsCompleted + 1)/\(maxMiniSets) -- same weight!",
                    suggestedWeightKg: weight,
                    restSeconds: miniRestSeconds,
                    prescribedReps: miniSetReps,
                    isTerminal: miniSetsCompleted + 1 >= maxMiniSets,
                    lockWeight: true
                )
            }
        }

        // All existing sets done -- need to add a dynamic mini-set
        let nextIdx = ex.sets.count
        let weight = lastWorkingWeight(ex) ?? lastCompletedWeightAny(ex)

        return TechniqueStep(
            exerciseIndex: exerciseIndex,
            setIndex: nextIdx,
            instruction: "Mini-set \(miniSetsCompleted + 1)/\(maxMiniSets) -- same weight!",
            suggestedWeightKg: weight,
            restSeconds: miniRestSeconds,
            prescribedReps: miniSetReps,
            isTerminal: miniSetsCompleted + 1 >= maxMiniSets,
            lockWeight: true
        )
    }
}
