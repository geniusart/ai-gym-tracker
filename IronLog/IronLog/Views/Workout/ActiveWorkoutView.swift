import SwiftUI

struct ActiveWorkoutView: View {
    @Bindable var vm: ActiveWorkoutViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showExerciseList = false
    @State private var showNoteSheet = false

    var body: some View {
        ZStack {
            CockpitPalette.background.ignoresSafeArea()
            if canRenderWorkout {
                switch vm.setPhase {
                case .ready:
                    ReadyPhaseView(vm: vm)
                case .performing:
                    PerformingPhaseView(vm: vm)
                case .resting:
                    RestingPhaseView(vm: vm)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CockpitPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showExerciseList = true
                } label: {
                    Text(progressTitle)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(CockpitPalette.panelElevated, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(CockpitPalette.border)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canRenderWorkout)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { vm.beginFinishing() } label: {
                    Image(systemName: "flag.checkered")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(CockpitPalette.panelElevated, in: Circle())
                        .overlay {
                            Circle().strokeBorder(CockpitPalette.border)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish workout")
                .disabled(!canRenderWorkout)
            }
            ToolbarItemGroup(placement: .cancellationAction) {
                Button {
                    showExerciseList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 42, height: 42)
                        .background(CockpitPalette.panelElevated, in: Circle())
                        .overlay {
                            Circle().strokeBorder(CockpitPalette.border)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show exercises")
                .disabled(!canRenderWorkout)

                Button {
                    showNoteSheet = true
                } label: {
                    Image(systemName: currentExerciseHasNote ? "note.text" : "note.text.badge.plus")
                        .foregroundStyle(currentExerciseHasNote ? CockpitPalette.blue : .primary)
                        .frame(width: 42, height: 42)
                        .background(CockpitPalette.panelElevated, in: Circle())
                        .overlay {
                            Circle().strokeBorder(
                                currentExerciseHasNote
                                    ? CockpitPalette.blue.opacity(0.38)
                                    : CockpitPalette.border
                            )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(currentExerciseHasNote ? "Edit exercise note" : "Add exercise note")
                .disabled(!canEditCurrentExerciseNote)
            }
        }
        .sheet(isPresented: $showExerciseList) {
            ExerciseListSheet(vm: vm, isPresented: $showExerciseList)
        }
        .sheet(isPresented: $showNoteSheet) {
            ExerciseNoteSheet(vm: vm)
        }
        .sheet(isPresented: isFinishing) {
            FinishWorkoutSheet(vm: vm)
        }
        .onChange(of: vm.state) { _, newState in
            if case .saved = newState {
                vm.reset()
                dismiss()
            }
        }
        .alert(
            "Save Failed",
            isPresented: Binding(
                get: { vm.persistenceErrorMessage != nil },
                set: { if !$0 { vm.persistenceErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                vm.persistenceErrorMessage = nil
            }
        } message: {
            Text(vm.persistenceErrorMessage ?? "")
        }
    }

    private var progressTitle: String {
        guard !vm.exercises.isEmpty else { return "Exercise 0/0" }
        let current = min(vm.currentExerciseIndex + 1, vm.exercises.count)
        return "Exercise \(current)/\(vm.exercises.count)"
    }

    private var canRenderWorkout: Bool {
        guard !vm.exercises.isEmpty else { return false }
        switch vm.state {
        case .idle, .saved:
            return false
        default:
            return true
        }
    }

    private var canEditCurrentExerciseNote: Bool {
        canRenderWorkout && vm.currentExercise != nil
    }

    private var currentExerciseHasNote: Bool {
        canEditCurrentExerciseNote
            && !vm.exerciseNote(at: vm.currentExerciseIndex).isEmpty
    }

    private var isFinishing: Binding<Bool> {
        Binding(
            get: {
                if case .finishing = vm.state { return true }
                return false
            },
            set: { if !$0 { vm.cancelFinishing() } }
        )
    }
}

// MARK: - Ready Phase: slider right=start, left=set weight

private struct ReadyPhaseView: View {
    @Bindable var vm: ActiveWorkoutViewModel
    @State private var showFullHint = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ExerciseProgressCells(vm: vm)

                ExerciseHeader(vm: vm)

                if let hint = vm.currentExercise?.notes, !hint.isEmpty {
                    ExerciseHintPanel(
                        hint: hint,
                        isExpanded: $showFullHint
                    )
                }

                if let instruction = visibleFlowInstruction {
                    FlowInstructionPanel(
                        text: instruction,
                        isDrop: vm.currentSet?.type == "drop"
                    )
                }

                SetRoadmap(vm: vm)

                Spacer(minLength: 8)
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    vm.readySlideRight()
                } label: {
                    Label("Start set", systemImage: "play.fill")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(CockpitPrimaryButtonStyle(tint: CockpitPalette.blue))

                Button("Skip exercise") { vm.skipExercise() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CockpitPalette.muted)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(CockpitPalette.background.opacity(0.96))
        }
        .onChange(of: vm.currentExerciseIndex) { _, _ in
            showFullHint = false
        }
    }

    private var visibleFlowInstruction: String? {
        let instruction = vm.flowInstruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }

        if let exercise = vm.currentExercise,
           exercise.technique == "superset",
           isRedundantSupersetInstruction(instruction, exerciseName: exercise.name) {
            return nil
        }
        return instruction
    }

    private func isRedundantSupersetInstruction(
        _ instruction: String,
        exerciseName: String
    ) -> Bool {
        instruction.hasPrefix("\(exerciseName):")
            || instruction == "Now: \(exerciseName)"
    }
}

// MARK: - Performing Phase: weight + reps adjustable, Done to finish

private struct PerformingPhaseView: View {
    @Bindable var vm: ActiveWorkoutViewModel
    @State private var weight: Double = 0
    @State private var reps: Int = 10
    @State private var showFullHint = false

    var body: some View {
        VStack(spacing: 14) {
            ExerciseProgressCells(vm: vm)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            PerformingExerciseTitle(vm: vm)
                .padding(.horizontal, 16)

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Text(vm.setStopwatch.formattedTime)
                    .font(.system(size: 78, weight: .thin, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(motivationText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CockpitPalette.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)

            if let hint = vm.currentExercise?.notes, !hint.isEmpty {
                CollapsedHintLine(
                    hint: hint,
                    isExpanded: $showFullHint
                )
                .padding(.horizontal, 16)
            }

            CurrentSetPanel(vm: vm)
                .padding(.horizontal, 16)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                EditableMetricPanel(
                    title: "Weight",
                    value: formatWeight(weight),
                    unit: "kg",
                    isLocked: vm.flowLockWeight,
                    decrement: { weight = max(0, weight - weightStep) },
                    increment: { weight += weightStep }
                )

                EditableMetricPanel(
                    title: "Reps",
                    value: "\(reps)",
                    unit: "reps",
                    isLocked: false,
                    decrement: { reps = max(1, reps - 1) },
                    increment: { reps += 1 }
                )
            }
            .padding(.horizontal, 16)

            Button {
                vm.confirmPerforming(weight: weight, reps: reps)
            } label: {
                Text("Done")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(CockpitPrimaryButtonStyle(tint: CockpitPalette.green))
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(CockpitPalette.background)
        .onAppear {
            weight = vm.currentSet?.weightKg ?? vm.lastCompletedWeight ?? 0
            reps = vm.currentSet?.prescribedReps ?? 10
        }
        .onChange(of: vm.currentExerciseIndex) { _, _ in
            showFullHint = false
        }
    }

    private var weightStep: Double {
        weight.truncatingRemainder(dividingBy: 1) == 0 ? 1 : 0.5
    }

    private var motivationText: String {
        if let tempo = vm.currentExercise?.tempo, !tempo.isEmpty {
            return "Tempo \(tempo). Smooth reps."
        }
        return "Hold top 1 sec. Smooth reps."
    }
}

private struct PerformingExerciseTitle: View {
    let vm: ActiveWorkoutViewModel

    var body: some View {
        if let exercise = vm.currentExercise {
            CockpitPanel(spacing: 8, padding: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(exercise.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Set \(vm.currentSetIndex + 1) of \(exercise.sets.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(CockpitPalette.muted)
                        .lineLimit(1)
                    .layoutPriority(1)
                }

                HStack(spacing: 8) {
                    if let technique = techniqueLabel(for: exercise) {
                        CockpitChip(
                            text: technique.text,
                            color: technique.color,
                            systemImage: technique.systemImage
                        )
                    }
                    if let setType = setTypeLabel {
                        CockpitChip(
                            text: setType.text,
                            color: setType.color
                        )
                    }
                }

                if let remaining = vm.remainingWorkoutMinutesText {
                    HStack {
                        Spacer()
                        RemainingTimePill(text: remaining)
                    }
                }
            }
        }
    }

    private var setTypeLabel: (text: String, color: Color)? {
        SetTypeStyle.badge(vm.currentSet?.type).map { ($0.label, $0.color) }
    }

    private func techniqueLabel(
        for exercise: ExerciseState
    ) -> (text: String, color: Color, systemImage: String?)? {
        if exercise.supersetPartnerIndex != nil || exercise.technique == "superset" {
            return ("Superset", CockpitPalette.purple, "arrow.triangle.2.circlepath")
        }
        switch exercise.technique {
        case "drop_set":
            return ("Drop set", CockpitPalette.amber, nil)
        case "rest_pause":
            return ("Rest-pause", CockpitPalette.cyan, nil)
        case "myo_reps":
            return ("Myo-reps", CockpitPalette.magenta, nil)
        default:
            return nil
        }
    }
}

// MARK: - Resting Phase

private struct RestingPhaseView: View {
    @Bindable var vm: ActiveWorkoutViewModel

    var body: some View {
        Group {
            if vm.isRestBeforeNextExercise {
                BetweenExercisesRestView(vm: vm, nextInfo: nextInfo)
            } else {
                VStack(spacing: 16) {
                    ExerciseProgressCells(vm: vm)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    NextSetPanel(
                        info: nextInfo,
                        remainingTimeText: vm.remainingWorkoutMinutesText
                    )
                        .padding(.horizontal, 16)

                    Spacer()

                    Button {
                        vm.onRestFinished()
                    } label: {
                        let overtime = vm.restTimer.isOvertime
                        VStack(spacing: 10) {
                            Text(vm.restTimer.formattedTime)
                                .font(.system(size: 58, weight: .light, design: .monospaced))
                                .monospacedDigit()
                            Text(restActionText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 238, height: 238)
                        .background(
                            Circle().fill(overtime ? CockpitPalette.amber.opacity(0.24) : CockpitPalette.blue.opacity(0.22))
                        )
                        .overlay {
                            Circle()
                                .stroke(overtime ? CockpitPalette.amber.opacity(0.20) : CockpitPalette.blue.opacity(0.22), lineWidth: 6)
                            Circle()
                                .trim(from: 0, to: 1.0 - vm.restTimer.progress)
                                .stroke(
                                    overtime ? CockpitPalette.amber : CockpitPalette.blue,
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.5), value: vm.restTimer.progress)
                        }
                    }
                    .buttonStyle(.plain)
                    .shadow(color: vm.restTimer.isOvertime ? CockpitPalette.amber.opacity(0.32) : CockpitPalette.blue.opacity(0.30), radius: 14)
                    .accessibilityLabel(restActionAccessibilityLabel)

                    Spacer()

                    if vm.isDynamicFlow {
                        Button("Finish exercise") { vm.finishExercise() }
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.bottom, 16)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .background(CockpitPalette.background)
    }

    private var restActionText: String {
        guard vm.restStartsNextSetImmediately else {
            return "Start when ready"
        }
        return vm.currentSet?.type == "myo_mini"
            ? "Start mini-set"
            : "Start set"
    }

    private var restActionAccessibilityLabel: String {
        restActionText
    }

    private var nextInfo: NextSetInfo {
        if vm.isRestBeforeNextExercise {
            // Must match the executor's walk: `currentExerciseIndex + 1` names
            // the junior superset partner the user has already finished.
            guard let nextIdx = vm.nextExerciseIndexAfterCurrentFlow() else {
                return NextSetInfo(
                    eyebrow: "NEXT",
                    title: "Workout complete",
                    subtitle: nil,
                    badge: nil,
                    metrics: [],
                    tint: CockpitPalette.green
                )
            }
            let next = vm.exercises[nextIdx]
            let firstSet = next.sets.first
            let techniqueBadge = techniqueBadge(for: next)
            return NextSetInfo(
                eyebrow: "NEXT EXERCISE",
                title: next.name,
                subtitle: firstSet.map { _ in "Set 1" },
                badge: techniqueBadge ?? firstSet.flatMap { setBadge(for: $0.type) },
                secondaryBadge: techniqueBadge == nil ? nil : firstSet.flatMap { setBadge(for: $0.type) },
                metrics: firstSet.map(nextMetrics(for:)) ?? [],
                tint: techniqueColor(for: next)
            )
        }

        if let set = vm.currentSet {
            let setTitle = "Set \(vm.currentSetIndex + 1)"
            var subtitleParts = [setTitle]
            if !vm.flowInstruction.isEmpty {
                subtitleParts.append(vm.flowInstruction)
            }
            return NextSetInfo(
                eyebrow: "NEXT",
                title: vm.currentExercise?.name ?? setTitle,
                subtitle: subtitleParts.joined(separator: " · "),
                badge: setBadge(for: set.type),
                metrics: nextMetrics(for: set),
                tint: setBadge(for: set.type)?.color ?? CockpitPalette.blue
            )
        }

        return NextSetInfo(
            eyebrow: "NEXT",
            title: "Done",
            subtitle: nil,
            badge: nil,
            metrics: [],
            tint: CockpitPalette.green
        )
    }

    private func nextMetrics(for set: SetState) -> [NextSetMetric] {
        var metrics: [NextSetMetric] = []
        if let weight = set.weightKg ?? set.prescribedWeightKg {
            metrics.append(
                NextSetMetric(label: "Load", value: formatWeight(weight), unit: "kg", tint: .primary)
            )
        }
        if let reps = set.prescribedReps ?? set.reps {
            metrics.append(
                NextSetMetric(label: "Reps", value: "\(reps)", unit: "reps", tint: .primary)
            )
        }
        if let rir = set.prescribedRir {
            metrics.append(
                NextSetMetric(label: "RIR", value: "\(rir)", unit: "reps left", tint: CockpitPalette.faint)
            )
        }
        return metrics
    }

    private func setBadge(for type: String) -> NextSetBadge? {
        SetTypeStyle.badge(type).map { NextSetBadge(text: $0.label, color: $0.color) }
    }

    private func techniqueBadge(for exercise: ExerciseState) -> NextSetBadge? {
        if exercise.supersetPartnerIndex != nil || exercise.technique == "superset" {
            return NextSetBadge(text: "Superset", color: CockpitPalette.purple)
        }
        switch exercise.technique {
        case "drop_set": return NextSetBadge(text: "Drop set", color: CockpitPalette.amber)
        case "rest_pause": return NextSetBadge(text: "Rest-pause", color: CockpitPalette.cyan)
        case "myo_reps": return NextSetBadge(text: "Myo-reps", color: CockpitPalette.magenta)
        default: return nil
        }
    }

    private func techniqueColor(for exercise: ExerciseState) -> Color {
        if exercise.supersetPartnerIndex != nil || exercise.technique == "superset" {
            return CockpitPalette.purple
        }
        switch exercise.technique {
        case "drop_set": return CockpitPalette.amber
        case "rest_pause": return CockpitPalette.cyan
        case "myo_reps": return CockpitPalette.magenta
        default: return CockpitPalette.blue
        }
    }
}

private struct BetweenExercisesRestView: View {
    @Bindable var vm: ActiveWorkoutViewModel
    let nextInfo: NextSetInfo

    private var nextExerciseIndex: Int? {
        vm.nextExerciseIndexAfterCurrentFlow()
    }

    private var scrollTargetIndex: Int? {
        if let nextExerciseIndex { return nextExerciseIndex }
        return vm.exercises.indices.contains(vm.currentExerciseIndex)
            ? vm.currentExerciseIndex
            : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            ExerciseProgressCells(vm: vm)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        NextSetPanel(
                            info: nextInfo,
                            remainingTimeText: vm.remainingWorkoutMinutesText
                        )

                        InlineRatingBar(vm: vm)

                        WorkoutExerciseMap(
                            vm: vm,
                            highlightIndex: nextExerciseIndex ?? vm.currentExerciseIndex,
                            onSelect: nil
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 112)
                }
                .onAppear {
                    if let scrollTargetIndex {
                        proxy.scrollTo(scrollTargetIndex, anchor: .center)
                    }
                }
                .onChange(of: nextExerciseIndex) { _, newValue in
                    if let target = newValue ?? scrollTargetIndex {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            RestCountdownStartButton(
                timer: vm.restTimer,
                title: nextExerciseIndex == nil ? "Finish workout" : "Start next exercise"
            ) {
                vm.onRestFinished()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(CockpitPalette.background.opacity(0.96))
        }
        .background(CockpitPalette.background)
    }
}

private struct RestCountdownStartButton: View {
    let timer: RestTimerService
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.bold))
                    Text(timer.isOvertime ? "Rest complete" : "Rest countdown")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                Text(timer.isOvertime ? "Start" : timer.formattedTime)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                timer.isOvertime ? CockpitPalette.green : CockpitPalette.blue,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(alignment: .bottomLeading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.white.opacity(0.38))
                        .frame(width: proxy.size.width * min(max(timer.progress, 0), 1), height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(timer.formattedTime)
    }
}

// MARK: - Shared

private struct ExerciseHeader: View {
    let vm: ActiveWorkoutViewModel

    var body: some View {
        if let ex = vm.currentExercise {
            CockpitPanel(spacing: 10) {
                exerciseTitleContent(ex)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let remaining = vm.remainingWorkoutMinutesText {
                    HStack {
                        Spacer()
                        RemainingTimePill(text: remaining)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func exerciseTitleContent(_ ex: ExerciseState) -> some View {
        if let partnerIdx = ex.supersetPartnerIndex,
           vm.exercises.indices.contains(partnerIdx) {
            SupersetExercisePair(
                firstName: ex.name,
                secondName: vm.exercises[partnerIdx].name
            )
        } else if ex.supersetPartnerIndex != nil {
            Text(ex.name)
                .font(.title2.weight(.bold))
                .lineLimit(2)

            CockpitChip(
                text: "Superset link unavailable",
                color: CockpitPalette.amber,
                systemImage: "exclamationmark.triangle"
            )
        } else {
            Text(ex.name)
                .font(.title2.weight(.bold))
                .lineLimit(2)

            HStack(spacing: 8) {
                CockpitChip(
                    text: bodyPartLabel(ex.bodyPart),
                    color: CockpitPalette.muted,
                    systemImage: "scope"
                )
                if let equipment = ex.equipment, !equipment.isEmpty {
                    CockpitChip(
                        text: equipment,
                        color: CockpitPalette.faint,
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                if let name = vm.currentFlow?.displayName {
                    CockpitChip(
                        text: name,
                        color: techniqueBadgeColor(ex.technique)
                    )
                }
            }
        }
    }

    private func techniqueBadgeColor(_ technique: String) -> Color {
        TechniqueStyle.color(technique)
    }

    private func bodyPartLabel(_ part: String) -> String {
        switch part {
        case "legs": return "Legs"
        case "chest": return "Chest"
        case "back": return "Back"
        case "shoulders": return "Shoulders"
        case "biceps": return "Biceps"
        case "triceps": return "Triceps"
        case "core": return "Core"
        default: return part.capitalized
        }
    }
}

private struct SupersetExercisePair: View {
    let firstName: String
    let secondName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(firstName)
                .font(.title2.weight(.bold))
                .lineLimit(2)

            HStack(spacing: 8) {
                Rectangle()
                    .fill(CockpitPalette.purple.opacity(0.34))
                    .frame(height: 1)

                CockpitChip(
                    text: "Superset",
                    color: CockpitPalette.purple,
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .fixedSize()

                Rectangle()
                    .fill(CockpitPalette.purple.opacity(0.34))
                    .frame(height: 1)
            }

            Text(secondName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct SetRoadmap: View {
    let vm: ActiveWorkoutViewModel
    var condensed: Bool = false

    var body: some View {
        if let ex = vm.currentExercise {
            CockpitPanel(spacing: 8) {
                HStack {
                    Text("Sets")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text("\(ex.sets.filter(\.isCompleted).count)/\(ex.sets.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(CockpitPalette.muted)
                }

                let completedCount = ex.sets.filter(\.isCompleted).count
                if completedCount > 0 {
                    CompletedSetsRow(count: completedCount)
                }

                let upcoming = Array(ex.sets.enumerated()).filter { !$0.element.isCompleted }
                ForEach(upcoming.prefix(condensed ? 3 : 5), id: \.element.id) { idx, s in
                    setRow(s, index: idx, isActive: idx == vm.currentSetIndex)
                }

                if upcoming.count > (condensed ? 3 : 5) {
                    Text("+\(upcoming.count - (condensed ? 3 : 5)) upcoming")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CockpitPalette.faint)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func setRow(_ s: SetState, index: Int, isActive: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Set \(index + 1)")
                .font(.subheadline.weight(isActive ? .bold : .semibold))
                .frame(width: 52, alignment: .leading)

            let typeLabel = setTypeLabel(s.type)
            if !typeLabel.isEmpty {
                Text(typeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(setTypeColor(s.type))
            }

            if let r = s.isCompleted ? s.reps : s.prescribedReps {
                Text("\(r) reps")
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
            }

            if let w = s.isCompleted ? s.weightKg : (s.weightKg ?? s.prescribedWeightKg) {
                Text("\(formatWeight(w)) kg")
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
            }

            if !s.isCompleted, let rir = s.prescribedRir {
                Text("RIR \(rir)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CockpitPalette.faint)
            }

            Spacer()
        }
        .foregroundStyle(isActive ? .primary : CockpitPalette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isActive ? CockpitPalette.blue.opacity(0.13) : CockpitPalette.panelElevated.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? CockpitPalette.blue.opacity(0.45) : CockpitPalette.border)
        }
    }

    private func setTypeLabel(_ type: String) -> String {
        SetTypeStyle.badge(type)?.label ?? ""
    }

    private func setTypeColor(_ type: String) -> Color {
        SetTypeStyle.badge(type)?.color ?? CockpitPalette.muted
    }
}

private struct ExerciseProgressCells: View {
    let vm: ActiveWorkoutViewModel

    var body: some View {
        let exercises = vm.exercises

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(progressGroups(for: exercises)) { group in
                    if group.isSupersetPair {
                        let groupCompleted = group.indices.allSatisfy { idx in
                            exercises.indices.contains(idx) && exercises[idx].sets.allSatisfy(\.isCompleted)
                        }
                        let groupCurrent = group.indices.contains(vm.currentExerciseIndex)

                        HStack(spacing: 6) {
                            ForEach(group.indices, id: \.self) { idx in
                                if exercises.indices.contains(idx) {
                                    progressCell(
                                        index: idx,
                                        exercise: exercises[idx],
                                        suppressSupersetMarker: true
                                    )
                                }
                            }
                        }
                        .frame(height: 34)
                        .overlay {
                            if !groupCompleted {
                                SupersetHorizontalBracket(color: groupCurrent ? CockpitPalette.blue : CockpitPalette.purple)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if !groupCompleted && !groupCurrent {
                                Capsule()
                                    .fill(CockpitPalette.purple)
                                    .frame(width: 28, height: 3)
                                    .offset(y: -2)
                            }
                        }
                    } else if let idx = group.indices.first {
                        if exercises.indices.contains(idx) {
                            progressCell(
                                index: idx,
                                exercise: exercises[idx],
                                suppressSupersetMarker: false
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func progressGroups(for exercises: [ExerciseState]) -> [ProgressCellGroup] {
        var groups: [ProgressCellGroup] = []
        var used = Set<Int>()

        for idx in exercises.indices {
            guard !used.contains(idx) else { continue }

            if let partner = supersetPartner(for: idx, in: exercises),
               exercises.indices.contains(partner),
               abs(partner - idx) == 1 {
                let indices = [idx, partner].sorted()
                groups.append(ProgressCellGroup(indices: indices, isSupersetPair: true))
                used.formUnion(indices)
            } else {
                groups.append(ProgressCellGroup(indices: [idx], isSupersetPair: false))
                used.insert(idx)
            }
        }

        return groups
    }

    private func supersetPartner(for index: Int, in exercises: [ExerciseState]) -> Int? {
        guard exercises.indices.contains(index) else { return nil }

        if let partner = exercises[index].supersetPartnerIndex {
            return partner
        }
        return exercises.firstIndex { $0.supersetPartnerIndex == index }
    }

    private func progressCell(
        index: Int,
        exercise: ExerciseState,
        suppressSupersetMarker: Bool
    ) -> some View {
        let completed = exercise.sets.allSatisfy(\.isCompleted)
        let current = index == vm.currentExerciseIndex
        let special = specialColor(
            for: exercise,
            suppressSuperset: suppressSupersetMarker
        )
        let visibleSpecial = completed || current ? nil : special
        let fill = statusFill(isCompleted: completed, isCurrent: current)

        return Text("\(index + 1)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(current || completed ? .white : CockpitPalette.muted)
            .frame(width: 30, height: 34)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if !completed {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            current ? CockpitPalette.blue.opacity(0.75) : CockpitPalette.border,
                            lineWidth: current ? 2 : 1
                        )
                }
            }
            .overlay(alignment: .bottom) {
                if let visibleSpecial {
                    Capsule()
                        .fill(visibleSpecial)
                        .frame(width: 14, height: 3)
                        .offset(y: -3)
                }
            }
            .accessibilityLabel("Exercise \(index + 1), \(exercise.name)")
    }

    private func statusFill(isCompleted: Bool, isCurrent: Bool) -> Color {
        if isCompleted { return CockpitPalette.green.opacity(0.95) }
        if isCurrent { return CockpitPalette.blue.opacity(0.95) }
        return CockpitPalette.panelElevated
    }

    private func specialColor(
        for exercise: ExerciseState,
        suppressSuperset: Bool
    ) -> Color? {
        if !suppressSuperset,
           (exercise.supersetPartnerIndex != nil || exercise.technique == "superset") {
            return CockpitPalette.purple
        }
        switch exercise.technique {
        case "drop_set": return CockpitPalette.amber
        case "rest_pause": return CockpitPalette.cyan
        case "myo_reps": return CockpitPalette.magenta
        default: return nil
        }
    }

    private struct ProgressCellGroup: Identifiable {
        let indices: [Int]
        let isSupersetPair: Bool

        var id: String {
            indices.map(String.init).joined(separator: "-")
        }
    }
}

private struct ExerciseHintPanel: View {
    let hint: String
    @Binding var isExpanded: Bool

    var body: some View {
        CockpitPanel(spacing: 8, padding: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CockpitPalette.amber)
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CockpitPalette.amber)
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(isExpanded ? .primary : CockpitPalette.muted)
                        .lineLimit(isExpanded ? nil : 1)
                    Spacer(minLength: 8)
                    Button(isExpanded ? "Show less" : "Show more...") {
                        isExpanded.toggle()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CockpitPalette.amber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }
}

private struct CollapsedHintLine: View {
    let hint: String
    @Binding var isExpanded: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(CockpitPalette.amber)
                Text("Hint: \(hint)")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .multilineTextAlignment(.leading)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(CockpitPalette.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(CockpitPalette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(CockpitPalette.border)
            }

            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(CockpitPalette.amber)
                    Text("Hint: \(hint)")
                        .lineLimit(isExpanded ? 3 : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(CockpitPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CockpitPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(CockpitPalette.border)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowInstructionPanel: View {
    let text: String
    let isDrop: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDrop ? "arrow.down.circle.fill" : "info.circle.fill")
            Text(text)
                .lineLimit(2)
            Spacer()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isDrop ? CockpitPalette.amber : CockpitPalette.blue)
        .padding(12)
        .background((isDrop ? CockpitPalette.amber : CockpitPalette.blue).opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}

private struct CompletedSetsRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("\(count) done")
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(CockpitPalette.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CockpitPalette.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct CurrentSetPanel: View {
    let vm: ActiveWorkoutViewModel

    var body: some View {
        if let targetDetail {
            CockpitPanel(spacing: 6, padding: 12) {
                Text("Target")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CockpitPalette.faint)

                Text(targetDetail)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private var targetDetail: String? {
        var parts: [String] = []
        if let rir = vm.currentSet?.prescribedRir {
            parts.append("RIR \(rir)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct EditableMetricPanel: View {
    let title: String
    let value: String
    let unit: String
    let isLocked: Bool
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CockpitPalette.faint)
                Spacer()
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(CockpitPalette.faint)
                }
            }

            HStack(spacing: 8) {
                if !isLocked {
                    controlButton("minus", action: decrement)
                }

                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text(unit)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(CockpitPalette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(minWidth: 58)

                if !isLocked {
                    controlButton("plus", action: increment)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(CockpitPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CockpitPalette.border)
        }
    }

    private func controlButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.bold))
                .frame(width: 34, height: 34)
                .background(CockpitPalette.panelElevated, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct NextSetInfo {
    let eyebrow: String
    let title: String
    let subtitle: String?
    let badge: NextSetBadge?
    var secondaryBadge: NextSetBadge? = nil
    let metrics: [NextSetMetric]
    let tint: Color
}

private struct NextSetBadge {
    let text: String
    let color: Color
}

private struct NextSetMetric: Identifiable {
    let label: String
    let value: String
    let unit: String
    let tint: Color

    var id: String {
        "\(label)-\(value)-\(unit)"
    }
}

private struct NextSetPanel: View {
    let info: NextSetInfo
    let remainingTimeText: String?

    var body: some View {
        CockpitPanel(spacing: 12, padding: 14) {
            HStack(spacing: 8) {
                Text(info.eyebrow.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(info.tint)
                Spacer()
                if let badge = info.badge {
                    NextSetBadgeChip(badge: badge)
                }
                if let secondaryBadge = info.secondaryBadge {
                    NextSetBadgeChip(badge: secondaryBadge)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(info.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = info.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CockpitPalette.muted)
                        .lineLimit(2)
                }
            }

            if !info.metrics.isEmpty {
                HStack(spacing: 8) {
                    ForEach(info.metrics) { metric in
                        NextMetricTile(metric: metric)
                    }
                }
            }

            if let remainingTimeText {
                HStack {
                    Spacer()
                    RemainingTimePill(text: remainingTimeText)
                }
            }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(info.tint)
                .frame(width: 4)
                .padding(.vertical, 16)
        }
    }
}

private struct RemainingTimePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(CockpitPalette.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(CockpitPalette.panelElevated.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CockpitPalette.border)
            }
    }
}

private struct NextSetBadgeChip: View {
    let badge: NextSetBadge

    var body: some View {
        Text(badge.text)
            .font(.caption.weight(.bold))
            .foregroundStyle(badge.color)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badge.color.opacity(0.14), in: Capsule())
    }
}

private struct NextMetricTile: View {
    let metric: NextSetMetric

    var body: some View {
        VStack(spacing: 3) {
            Text(metric.label.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(CockpitPalette.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(metric.value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(metric.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text(metric.unit)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CockpitPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(CockpitPalette.panelElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CockpitPalette.border)
        }
        .accessibilityLabel("\(metric.label) \(metric.value) \(metric.unit)")
    }
}

private struct SupersetMapGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SupersetVerticalBracket(color: CockpitPalette.purple)
                .frame(width: 18)
                .padding(.vertical, 18)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.bold))
                    Text("Superset pair")
                        .font(.caption.weight(.bold))
                    Spacer()
                }
                .foregroundStyle(CockpitPalette.purple)
                .padding(.horizontal, 4)

                content
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SupersetHorizontalBracket: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            bracketPath(in: proxy.size)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
        }
        .allowsHitTesting(false)
    }

    private func bracketPath(in size: CGSize) -> Path {
        let inset: CGFloat = 1.5
        let arm = min(size.width * 0.18, 13)
        let radius: CGFloat = 5
        let top = inset
        let bottom = max(inset, size.height - inset)
        let right = max(inset, size.width - inset)

        var path = Path()

        path.move(to: CGPoint(x: arm, y: top))
        path.addLine(to: CGPoint(x: radius + inset, y: top))
        path.addQuadCurve(
            to: CGPoint(x: inset, y: top + radius),
            control: CGPoint(x: inset, y: top)
        )
        path.addLine(to: CGPoint(x: inset, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: radius + inset, y: bottom),
            control: CGPoint(x: inset, y: bottom)
        )
        path.addLine(to: CGPoint(x: arm, y: bottom))

        path.move(to: CGPoint(x: right - arm, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: right, y: top + radius),
            control: CGPoint(x: right, y: top)
        )
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: right - radius, y: bottom),
            control: CGPoint(x: right, y: bottom)
        )
        path.addLine(to: CGPoint(x: right - arm, y: bottom))

        return path
    }
}

private struct SupersetVerticalBracket: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            bracketPath(in: proxy.size)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
        }
        .allowsHitTesting(false)
    }

    private func bracketPath(in size: CGSize) -> Path {
        let inset: CGFloat = 1.5
        let radius: CGFloat = 7
        let top = inset
        let bottom = max(inset, size.height - inset)
        let right = max(inset, size.width - inset)

        var path = Path()
        path.move(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: radius + inset, y: top))
        path.addQuadCurve(
            to: CGPoint(x: inset, y: top + radius),
            control: CGPoint(x: inset, y: top)
        )
        path.addLine(to: CGPoint(x: inset, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: radius + inset, y: bottom),
            control: CGPoint(x: inset, y: bottom)
        )
        path.addLine(to: CGPoint(x: right, y: bottom))
        return path
    }
}

private struct ExerciseMapRow: View {
    let index: Int
    let exercise: ExerciseState
    let doneSets: Int
    let totalSets: Int
    let isCurrent: Bool
    let isCompleted: Bool
    let suppressSupersetBadge: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(isCurrent || isCompleted ? .white : CockpitPalette.muted)
                .frame(width: 32, height: 32)
                .background(statusColor, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            techniqueStripeColor ?? CockpitPalette.border,
                            lineWidth: techniqueStripeColor == nil ? 1 : 2
                        )
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(exercise.name)
                    .font(.subheadline.weight(isCurrent ? .bold : .semibold))
                    .lineLimit(2)
                    .foregroundStyle(isCompleted ? CockpitPalette.muted : .primary)

                HStack(spacing: 7) {
                    Text(bodyPartLabel(exercise.bodyPart))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(CockpitPalette.faint)

                    if let technique = techniqueBadge {
                        Text(technique.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(technique.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(technique.color.opacity(0.12), in: Capsule())
                    }
                }
            }

            Spacer()

            Text("\(doneSets)/\(totalSets)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(isCompleted ? CockpitPalette.green : CockpitPalette.muted)
        }
        .padding(12)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            if techniqueStripeColor != nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(techniqueStripeColor ?? CockpitPalette.purple)
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isCurrent ? CockpitPalette.blue.opacity(0.55) : CockpitPalette.border)
        }
    }

    private var rowFill: Color {
        if isCurrent { return CockpitPalette.blue.opacity(0.14) }
        if isCompleted { return CockpitPalette.green.opacity(0.09) }
        return CockpitPalette.panel
    }

    private var statusColor: Color {
        if isCurrent { return CockpitPalette.blue }
        if isCompleted { return CockpitPalette.green }
        return CockpitPalette.panelElevated
    }

    private var techniqueStripeColor: Color? {
        if !suppressSupersetBadge,
           (exercise.supersetPartnerIndex != nil || exercise.technique == "superset") {
            return CockpitPalette.purple
        }
        switch exercise.technique {
        case "drop_set": return CockpitPalette.amber
        case "rest_pause": return CockpitPalette.cyan
        case "myo_reps": return CockpitPalette.magenta
        default: return nil
        }
    }

    private var techniqueBadge: (name: String, color: Color)? {
        if !suppressSupersetBadge,
           (exercise.supersetPartnerIndex != nil || exercise.technique == "superset") {
            return ("Superset", CockpitPalette.purple)
        }
        switch exercise.technique {
        case "drop_set": return ("Drop set", CockpitPalette.amber)
        case "rest_pause": return ("Rest-pause", CockpitPalette.cyan)
        case "myo_reps": return ("Myo-reps", CockpitPalette.magenta)
        default: return nil
        }
    }

    private func bodyPartLabel(_ part: String) -> String {
        switch part {
        case "legs": return "Legs"
        case "chest": return "Chest"
        case "back": return "Back"
        case "shoulders": return "Shoulders"
        case "biceps": return "Biceps"
        case "triceps": return "Triceps"
        case "core": return "Core"
        default: return part.capitalized
        }
    }

    private func techniqueName(_ technique: String) -> String {
        switch technique {
        case "drop_set": return "Drop"
        case "rest_pause": return "Rest-Pause"
        case "myo_reps": return "Myo"
        case "superset": return "Superset"
        default: return technique
        }
    }
}

private struct WorkoutExerciseMap: View {
    let vm: ActiveWorkoutViewModel
    let highlightIndex: Int
    let onSelect: ((Int) -> Void)?

    var body: some View {
        let exercises = vm.exercises

        LazyVStack(spacing: 10) {
            ForEach(exerciseGroups(for: exercises)) { group in
                if group.isSupersetPair {
                    SupersetMapGroup {
                        ForEach(group.indices, id: \.self) { idx in
                            exerciseRow(
                                index: idx,
                                in: exercises,
                                suppressSupersetBadge: true
                            )
                        }
                    }
                } else if let idx = group.indices.first {
                    exerciseRow(
                        index: idx,
                        in: exercises,
                        suppressSupersetBadge: false
                    )
                }
            }
        }
    }

    private func exerciseGroups(for exercises: [ExerciseState]) -> [ExerciseMapGroup] {
        var groups: [ExerciseMapGroup] = []
        var used = Set<Int>()

        for idx in exercises.indices {
            guard !used.contains(idx) else { continue }

            if let partner = supersetPartner(for: idx, in: exercises),
               exercises.indices.contains(partner),
               abs(partner - idx) == 1 {
                let indices = [idx, partner].sorted()
                groups.append(ExerciseMapGroup(indices: indices, isSupersetPair: true))
                used.formUnion(indices)
            } else {
                groups.append(ExerciseMapGroup(indices: [idx], isSupersetPair: false))
                used.insert(idx)
            }
        }

        return groups
    }

    private func supersetPartner(for index: Int, in exercises: [ExerciseState]) -> Int? {
        guard exercises.indices.contains(index) else { return nil }

        if let partner = exercises[index].supersetPartnerIndex {
            return partner
        }
        return exercises.firstIndex { $0.supersetPartnerIndex == index }
    }

    @ViewBuilder
    private func exerciseRow(
        index idx: Int,
        in exercises: [ExerciseState],
        suppressSupersetBadge: Bool
    ) -> some View {
        if exercises.indices.contains(idx) {
            let ex = exercises[idx]
            let doneSets = ex.sets.filter(\.isCompleted).count
            let totalSets = ex.sets.count
            let allDone = doneSets == totalSets
            let row = ExerciseMapRow(
                index: idx,
                exercise: ex,
                doneSets: doneSets,
                totalSets: totalSets,
                isCurrent: idx == highlightIndex,
                isCompleted: allDone,
                suppressSupersetBadge: suppressSupersetBadge
            )

            if let onSelect {
                Button {
                    onSelect(idx)
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .id(idx)
            } else {
                row.id(idx)
            }
        }
    }

    private struct ExerciseMapGroup: Identifiable {
        let indices: [Int]
        let isSupersetPair: Bool

        var id: String {
            indices.map(String.init).joined(separator: "-")
        }
    }
}

private struct WeightStepper: View {
    @Binding var weight: Double

    var body: some View {
        VStack(spacing: 12) {
            // Weight display
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(weight))")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text("kg")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            // Step buttons
            HStack(spacing: 12) {
                stepButton(label: "-5", delta: -5)
                stepButton(label: "-1", delta: -1)
                stepButton(label: "+1", delta: 1)
                stepButton(label: "+5", delta: 5)
            }
        }
    }

    private func stepButton(label: String, delta: Double) -> some View {
        Button {
            weight = max(0, weight + delta)
        } label: {
            Text(label)
                .font(.title3.weight(.semibold))
                .frame(width: 64, height: 48)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        }
        .tint(.primary)
    }
}

private struct ExerciseListButton: View {
    let vm: ActiveWorkoutViewModel
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .sheet(isPresented: $showSheet) {
            ExerciseListSheet(vm: vm, isPresented: $showSheet)
        }
    }
}

private struct ExerciseListSheet: View {
    let vm: ActiveWorkoutViewModel
    @Binding var isPresented: Bool

    var body: some View {
        let exercises = vm.exercises

        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(exerciseGroups(for: exercises)) { group in
                            if group.isSupersetPair {
                                SupersetMapGroup {
                                    ForEach(group.indices, id: \.self) { idx in
                                        exerciseButton(
                                            index: idx,
                                            in: exercises,
                                            suppressSupersetBadge: true
                                        )
                                    }
                                }
                            } else if let idx = group.indices.first {
                                exerciseButton(
                                    index: idx,
                                    in: exercises,
                                    suppressSupersetBadge: false
                                )
                            }
                        }
                    }
                    .padding(16)
                }
                .background(CockpitPalette.background)
                .navigationTitle("Exercises")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(CockpitPalette.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
                .onAppear {
                    if exercises.indices.contains(vm.currentExerciseIndex) {
                        proxy.scrollTo(vm.currentExerciseIndex, anchor: .center)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func exerciseGroups(for exercises: [ExerciseState]) -> [ExerciseMapGroup] {
        var groups: [ExerciseMapGroup] = []
        var used = Set<Int>()

        for idx in exercises.indices {
            guard !used.contains(idx) else { continue }

            if let partner = supersetPartner(for: idx, in: exercises),
               exercises.indices.contains(partner),
               abs(partner - idx) == 1 {
                let indices = [idx, partner].sorted()
                groups.append(ExerciseMapGroup(indices: indices, isSupersetPair: true))
                used.formUnion(indices)
            } else {
                groups.append(ExerciseMapGroup(indices: [idx], isSupersetPair: false))
                used.insert(idx)
            }
        }

        return groups
    }

    private func supersetPartner(for index: Int, in exercises: [ExerciseState]) -> Int? {
        guard exercises.indices.contains(index) else { return nil }

        if let partner = exercises[index].supersetPartnerIndex {
            return partner
        }
        return exercises.firstIndex { $0.supersetPartnerIndex == index }
    }

    @ViewBuilder
    private func exerciseButton(
        index idx: Int,
        in exercises: [ExerciseState],
        suppressSupersetBadge: Bool
    ) -> some View {
        if exercises.indices.contains(idx) {
            let ex = exercises[idx]
            let isCurrent = idx == vm.currentExerciseIndex
            let doneSets = ex.sets.filter(\.isCompleted).count
            let totalSets = ex.sets.count
            let allDone = doneSets == totalSets

            Button {
                vm.jumpToExercise(idx)
                isPresented = false
            } label: {
                ExerciseMapRow(
                    index: idx,
                    exercise: ex,
                    doneSets: doneSets,
                    totalSets: totalSets,
                    isCurrent: isCurrent,
                    isCompleted: allDone,
                    suppressSupersetBadge: suppressSupersetBadge
                )
            }
            .buttonStyle(.plain)
            .id(idx)
        }
    }

    private struct ExerciseMapGroup: Identifiable {
        let indices: [Int]
        let isSupersetPair: Bool

        var id: String {
            indices.map(String.init).joined(separator: "-")
        }
    }
}

// MARK: - Inline Exercise Rating (shown during rest before next exercise)

struct InlineRatingBar: View {
    @Bindable var vm: ActiveWorkoutViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text("How did it feel?")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ratingButton("Heavy", icon: "flame.fill", color: .red, value: 3)
                ratingButton("OK", icon: "hand.thumbsup.fill", color: .blue, value: 2)
                ratingButton("Easy", icon: "wind", color: .green, value: 1)
            }
        }
        .padding(.horizontal, 16)
    }

    private func ratingButton(
        _ label: String,
        icon: String,
        color: Color,
        value: Int
    ) -> some View {
        let selected = vm.pendingRating == value
        return Button {
            vm.setPendingRating(value)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                color.opacity(selected ? 0.30 : 0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(color, lineWidth: selected ? 2 : 0)
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

private func formatted(_ value: Double) -> String {
    String(format: "%.0f", value)
}

private func formatWeight(_ kg: Double) -> String {
    WorkoutFormatting.weight(kg)
}

// MARK: - Exercise Note Sheet

private struct ExerciseNoteSheet: View {
    @Bindable var vm: ActiveWorkoutViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var noteText: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // Coach notes (from plan) -- read-only
                if let coachNotes = vm.currentExercise?.notes,
                   !coachNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Coach", systemImage: "figure.strengthtraining.traditional")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(coachNotes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }

                // User note -- editable
                VStack(alignment: .leading, spacing: 4) {
                    Label("My note", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    TextEditor(text: $noteText)
                        .font(.body)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer()
            }
            .padding()
            .navigationTitle(vm.currentExercise?.name ?? "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.saveExerciseNote(
                            noteText,
                            forExerciseAt: vm.currentExerciseIndex
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                noteText = vm.exerciseNote(at: vm.currentExerciseIndex)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Finish Sheet

private struct FinishWorkoutSheet: View {
    @Bindable var vm: ActiveWorkoutViewModel
    @State private var effort: PerceivedEffort = .moderate
    #if DEBUG
    @State private var skipHealthKit = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("How hard was it?") {
                    Picker("Effort", selection: $effort) {
                        ForEach(PerceivedEffort.allCases, id: \.self) { e in
                            Text(e.label).tag(e)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    HStack {
                        Text("Completed sets")
                        Spacer()
                        Text("\(vm.completedSetsCount) / \(vm.totalSetsCount)")
                            .foregroundStyle(.secondary)
                    }
                }
                #if DEBUG
                Section {
                    Toggle("Skip Apple Health", isOn: $skipHealthKit)
                }
                #endif
            }
            .navigationTitle("Finish Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { vm.cancelFinishing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.finishEffort = effort.logValue
                        #if DEBUG
                        vm.skipHealthKit = skipHealthKit
                        #endif
                        vm.saveWorkout()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

enum PerceivedEffort: String, CaseIterable {
    case easy, moderate, hard

    var label: String {
        switch self {
        case .easy: "Easy"
        case .moderate: "Moderate"
        case .hard: "Hard"
        }
    }

    var logValue: Int {
        switch self {
        case .easy: 1
        case .moderate: 2
        case .hard: 3
        }
    }
}
