import SwiftUI
import SwiftData

// MARK: - Polymorphic history item

/// Wraps either a strength workout (`SDWorkout`) or a cycling workout
/// (`SDCyclingWorkout`) so the history list can merge both kinds and
/// render them chronologically.
private enum HistoryItem: Identifiable {
    case strength(SDWorkout)
    case cycling(SDCyclingWorkout)

    var id: String {
        switch self {
        case .strength(let w): return "s:\(w.workoutId)"
        case .cycling(let w):  return "c:\(w.workoutId)"
        }
    }

    var startedAt: Date {
        switch self {
        case .strength(let w): return w.startedAt
        case .cycling(let w):  return w.startedAt
        }
    }
}

struct WorkoutHistoryView: View {
    @Query(
        filter: #Predicate<SDWorkout> { $0.finishedAt != nil },
        sort: \SDWorkout.startedAt,
        order: .reverse
    ) private var strengthWorkouts: [SDWorkout]
    @Query(
        filter: #Predicate<SDCyclingWorkout> { $0.finishedAt != nil },
        sort: \SDCyclingWorkout.startedAt,
        order: .reverse
    ) private var cyclingWorkouts: [SDCyclingWorkout]

    @Environment(\.modelContext) private var modelContext
    @State private var syncingIds: Set<String> = []
    @State private var errorMessage: String?

    private var allItems: [HistoryItem] {
        let s = strengthWorkouts.map(HistoryItem.strength)
        let c = cyclingWorkouts.map(HistoryItem.cycling)
        return (s + c).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allItems.isEmpty {
                    ContentUnavailableView(
                        "No workouts yet",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Completed workouts will appear here")
                    )
                } else {
                    List {
                        ForEach(allItems) { item in
                            switch item {
                            case .strength(let w):
                                strengthRow(w)
                            case .cycling(let w):
                                cyclingRow(w)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 10, for: .scrollContent)
                    .contentMargins(.bottom, 112, for: .scrollContent)
                    .background(CockpitPalette.background)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CockpitPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert(
                "History Error",
                isPresented: .init(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func strengthRow(_ workout: SDWorkout) -> some View {
        NavigationLink {
            WorkoutDetailView(workout: workout)
        } label: {
            StrengthWorkoutRow(
                workout: workout,
                isSyncing: syncingIds.contains(workout.workoutId)
            )
        }
        .swipeActions(edge: .leading) {
            if workout.syncedAt == nil,
               SyncService.isAuthenticated,
               !syncingIds.contains(workout.workoutId) {
                Button {
                    syncStrength(workout)
                } label: {
                    Label("Sync", systemImage: "arrow.up.icloud")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteStrength(workout)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func cyclingRow(_ workout: SDCyclingWorkout) -> some View {
        NavigationLink {
            CyclingWorkoutDetailView(workout: workout)
        } label: {
            CyclingWorkoutRow(
                workout: workout,
                isSyncing: syncingIds.contains(workout.workoutId)
            )
        }
        .swipeActions(edge: .leading) {
            if workout.syncedAt == nil,
               SyncService.isAuthenticated,
               !syncingIds.contains(workout.workoutId) {
                Button {
                    syncCycling(workout)
                } label: {
                    Label("Sync", systemImage: "arrow.up.icloud")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteCycling(workout)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Actions

    private func syncStrength(_ workout: SDWorkout) {
        let id = workout.workoutId
        syncingIds.insert(id)
        Task {
            _ = await WorkoutSyncService.uploadStrength(
                workout,
                context: modelContext,
                force: true
            )
            syncingIds.remove(id)
        }
    }

    private func syncCycling(_ workout: SDCyclingWorkout) {
        let id = workout.workoutId
        syncingIds.insert(id)
        Task {
            _ = await WorkoutSyncService.uploadCycling(
                workout,
                context: modelContext,
                force: true
            )
            syncingIds.remove(id)
        }
    }

    private func deleteStrength(_ workout: SDWorkout) {
        let workoutId = workout.workoutId
        // An upload already in flight will upsert this workout server-side
        // after the local row is gone, so the DELETE has to be issued for a
        // syncing workout too -- not only for one that finished syncing.
        let existsRemotely = workout.syncedAt != nil || syncingIds.contains(workoutId)
        modelContext.delete(workout)
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Could not delete workout: \(error.localizedDescription)"
            return
        }
        if existsRemotely, SyncService.isConfigured, SyncService.isAuthenticated {
            Task.detached {
                try? await SyncService.deleteWorkout(workoutId)
            }
        }
    }

    private func deleteCycling(_ workout: SDCyclingWorkout) {
        let workoutId = workout.workoutId
        // An upload already in flight will upsert this workout server-side
        // after the local row is gone, so the DELETE has to be issued for a
        // syncing workout too -- not only for one that finished syncing.
        let existsRemotely = workout.syncedAt != nil || syncingIds.contains(workoutId)
        modelContext.delete(workout)
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Could not delete cycling workout: \(error.localizedDescription)"
            return
        }
        if existsRemotely, SyncService.isConfigured, SyncService.isAuthenticated {
            Task.detached {
                try? await SyncService.deleteWorkout(workoutId)
            }
        }
    }
}

// MARK: - Strength Workout Row

private struct StrengthWorkoutRow: View {
    let workout: SDWorkout
    var isSyncing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "dumbbell.fill")
                            .foregroundStyle(CockpitPalette.blue)
                            .font(.caption)
                        Text(workout.templateName)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                    }
                    if let plan = workout.planName {
                        HStack(spacing: 4) {
                            Text(plan)
                            if let v = workout.planVersion {
                                Text("v\(v)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(CockpitPalette.muted)
                        .lineLimit(1)
                    }
                }
                Spacer()
                syncIcon(isSyncing: isSyncing, syncedAt: workout.syncedAt)
                if let effort = workout.perceivedEffort {
                    strengthEffortBadge(effort)
                }
            }

            HStack(spacing: 12) {
                Label(formattedDate(workout.startedAt), systemImage: "calendar")
                if let dur = workout.durationMinutes {
                    Label("\(Int(dur)) min", systemImage: "clock")
                }
                Label(
                    "\(workout.exercises.count) exercises",
                    systemImage: "list.number"
                )
            }
            .font(.caption)
            .foregroundStyle(CockpitPalette.muted)
        }
        .padding(12)
        .background(CockpitPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CockpitPalette.border)
        }
    }
}

// MARK: - Cycling Workout Row

private struct CyclingWorkoutRow: View {
    let workout: SDCyclingWorkout
    var isSyncing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "bicycle")
                            .foregroundStyle(CockpitPalette.blue)
                            .font(.caption)
                        Text(workout.templateName)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                    }
                    if let plan = workout.planName {
                        HStack(spacing: 4) {
                            Text(plan)
                            if let v = workout.planVersion {
                                Text("v\(v)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(CockpitPalette.muted)
                        .lineLimit(1)
                    }
                }
                Spacer()
                syncIcon(isSyncing: isSyncing, syncedAt: workout.syncedAt)
                if let effort = workout.perceivedEffort {
                    cyclingEffortBadge(effort)
                }
            }

            HStack(spacing: 12) {
                Label(formattedDate(workout.startedAt), systemImage: "calendar")
                Label(
                    "\(workout.totalDurationSeconds / 60) min",
                    systemImage: "clock"
                )
                if workout.hadHrSource, let avg = workout.averageHr {
                    Label("avg \(avg)", systemImage: "heart")
                }
                Label("\(workout.segments.count) segments", systemImage: "list.number")
            }
            .font(.caption)
            .foregroundStyle(CockpitPalette.muted)
        }
        .padding(12)
        .background(CockpitPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CockpitPalette.border)
        }
    }
}

// MARK: - Sync icon helper

@ViewBuilder
private func syncIcon(isSyncing: Bool, syncedAt: Date?) -> some View {
    if isSyncing {
        ProgressView().controlSize(.mini)
    } else if syncedAt != nil {
        Image(systemName: "checkmark.icloud")
            .foregroundStyle(.green)
            .font(.caption)
    } else if SyncService.isAuthenticated {
        Image(systemName: "icloud.slash")
            .foregroundStyle(.secondary)
            .font(.caption)
    }
}

private func formattedDate(_ d: Date) -> String {
    d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
}

// Effort badges -- different scales:
// strength = 1-3 (Easy/Moderate/Hard); cycling = 1-10.

@ViewBuilder
private func strengthEffortBadge(_ effort: Int) -> some View {
    let (label, color): (String, Color) = switch effort {
    case 1: ("Easy", .green)
    case 2: ("Moderate", .orange)
    case 3: ("Hard", .red)
    default: ("?", .gray)
    }
    Text(label)
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
}

@ViewBuilder
private func cyclingEffortBadge(_ effort: Int) -> some View {
    let color: Color = switch effort {
    case 1...3: .green
    case 4...6: .yellow
    case 7...8: .orange
    case 9...10: .red
    default: .gray
    }
    Text("\(effort)/10")
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
}

// MARK: - Strength Detail

struct WorkoutDetailView: View {
    let workout: SDWorkout
    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkoutDetailSummaryCard(workout: workout)

                ForEach(sortedExercises) { exLog in
                    StrengthExerciseDetailCard(exercise: exLog)
                }
            }
            .padding(16)
            .padding(.bottom, 26)
        }
        .scrollContentBackground(.hidden)
        .background(CockpitPalette.background.ignoresSafeArea())
        .navigationTitle(workout.templateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CockpitPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .bottomBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    item: WorkoutExportService.exportJSON(workout),
                    preview: SharePreview(
                        "\(workout.templateName).json",
                        image: Image(systemName: "doc.text")
                    )
                )
            }
        }
    }

    private var sortedExercises: [SDExerciseLog] {
        workout.exercises.sorted { $0.order < $1.order }
    }
}

// MARK: - Cycling Detail

struct CyclingWorkoutDetailView: View {
    let workout: SDCyclingWorkout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CyclingDetailSummaryCard(workout: workout)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Segments")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(CockpitPalette.muted)
                        .padding(.horizontal, 2)

                    ForEach(sortedSegments) { seg in
                        CyclingSegmentDetailCard(seg: seg)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 26)
        }
        .background(CockpitPalette.background.ignoresSafeArea())
        .navigationTitle(workout.templateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CockpitPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    item: WorkoutExportService.exportCyclingJSON(workout),
                    preview: SharePreview(
                        "\(workout.templateName).json",
                        image: Image(systemName: "doc.text")
                    )
                )
            }
        }
    }

    private var sortedSegments: [SDCyclingSegmentLog] {
        workout.segments.sorted { $0.sortOrder < $1.sortOrder }
    }
}

private struct WorkoutDetailSummaryCard: View {
    let workout: SDWorkout

    var body: some View {
        CockpitPanel(spacing: 14) {
            DetailSectionHeader(title: "Summary", icon: "chart.bar.doc.horizontal")

            DetailMetricGrid {
                DetailMetricTile(
                    label: "Date",
                    value: workout.startedAt.formatted(.dateTime.day().month(.abbreviated).year()),
                    footnote: workout.startedAt.formatted(.dateTime.hour().minute()),
                    tint: CockpitPalette.blue
                )

                if let dur = workout.durationMinutes {
                    DetailMetricTile(
                        label: "Duration",
                        value: "\(Int(dur))",
                        footnote: "min",
                        tint: .primary
                    )
                }

                if let effort = workout.perceivedEffort {
                    let info = strengthEffortInfo(effort)
                    DetailMetricTile(
                        label: "Effort",
                        value: info.label,
                        footnote: "session",
                        tint: info.color
                    )
                }

                DetailMetricTile(
                    label: "Exercises",
                    value: "\(workout.exercises.count)",
                    footnote: "logged",
                    tint: CockpitPalette.muted
                )
            }
        }
    }
}

private struct CyclingDetailSummaryCard: View {
    let workout: SDCyclingWorkout

    var body: some View {
        CockpitPanel(spacing: 14) {
            DetailSectionHeader(title: "Summary", icon: "chart.bar.doc.horizontal")

            DetailMetricGrid {
                DetailMetricTile(
                    label: "Date",
                    value: workout.startedAt.formatted(.dateTime.day().month(.abbreviated).year()),
                    footnote: workout.startedAt.formatted(.dateTime.hour().minute()),
                    tint: CockpitPalette.blue
                )
                DetailMetricTile(
                    label: "Duration",
                    value: formatDuration(workout.totalDurationSeconds),
                    footnote: "total",
                    tint: .primary
                )
                if workout.hadHrSource {
                    DetailMetricTile(
                        label: "Avg HR",
                        value: workout.averageHr.map(String.init) ?? "-",
                        footnote: "bpm",
                        tint: CockpitPalette.green
                    )
                    DetailMetricTile(
                        label: "Max HR",
                        value: workout.maxHr.map(String.init) ?? "-",
                        footnote: "bpm",
                        tint: CockpitPalette.amber
                    )
                } else {
                    DetailMetricTile(
                        label: "Heart rate",
                        value: "No",
                        footnote: "source",
                        tint: CockpitPalette.faint
                    )
                }
                if let cal = workout.calories {
                    DetailMetricTile(
                        label: "Calories",
                        value: "\(cal)",
                        footnote: "kcal",
                        tint: CockpitPalette.muted
                    )
                }
                if let effort = workout.perceivedEffort {
                    DetailMetricTile(
                        label: "Effort",
                        value: "\(effort)/10",
                        footnote: "session",
                        tint: cyclingEffortColor(effort)
                    )
                }
            }

            if let notes = workout.workoutNotes, !notes.isEmpty {
                Text(notes)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CockpitPalette.muted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CockpitPalette.panelElevated.opacity(0.60), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct StrengthExerciseDetailCard: View {
    let exercise: SDExerciseLog

    var body: some View {
        CockpitPanel(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(exercise.exerciseName)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        if let bodyPart = exercise.bodyPart, !bodyPart.isEmpty {
                            CockpitChip(
                                text: bodyPartLabel(bodyPart),
                                color: CockpitPalette.muted,
                                systemImage: "scope"
                            )
                        }
                        if let rating = exercise.exerciseRating {
                            CockpitChip(
                                text: ratingLabel(rating),
                                color: ratingColor(rating),
                                systemImage: "dial.medium"
                            )
                        }
                    }
                }
                Spacer()
                Text("\(exercise.sets.count)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(CockpitPalette.muted)
                    .accessibilityLabel("\(exercise.sets.count) sets")
            }

            VStack(spacing: 8) {
                ForEach(sortedSets) { setLog in
                    StrengthSetDetailRow(setLog: setLog)
                }
            }

            if let notes = exercise.exerciseNotes, !notes.isEmpty {
                Text(notes)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CockpitPalette.muted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CockpitPalette.panelElevated.opacity(0.60), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var sortedSets: [SDSetLog] {
        exercise.sets.sorted { $0.setNumber < $1.setNumber }
    }
}

private struct StrengthSetDetailRow: View {
    let setLog: SDSetLog

    var body: some View {
        HStack(spacing: 10) {
            Text("Set \(setLog.setNumber)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CockpitPalette.muted)
                .frame(width: 52, alignment: .leading)

            if let badge = setTypeBadge(setLog.setType) {
                Text(badge.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(badge.color.opacity(0.14), in: Capsule())
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if let weight = setLog.weightKg {
                    Text("\(formatWeight(weight)) kg")
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
                if let reps = setLog.reps {
                    Text("\(reps) reps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CockpitPalette.muted)
                        .lineLimit(1)
                }
                if let rir = setLog.rir {
                    Text("RIR \(rir)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CockpitPalette.faint)
                }
                if setLog.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(CockpitPalette.amber)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(CockpitPalette.panelElevated.opacity(0.60), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if let badge = setTypeBadge(setLog.setType) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(badge.color)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CockpitPalette.border)
        }
    }
}

private struct CyclingSegmentDetailCard: View {
    let seg: SDCyclingSegmentLog

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: kindIcon(seg.kind))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(kindColor(seg.kind))
                    .frame(width: 30, height: 30)
                    .background(kindColor(seg.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(seg.name)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Text(kindName(seg.kind))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(kindColor(seg.kind))
                }

                Spacer()

                Text(formatDuration(seg.durationSecondsActual))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)

                if seg.skipped {
                    Text("Skipped")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CockpitPalette.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(CockpitPalette.amber.opacity(0.14), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                if let lo = seg.targetMinBpm, let hi = seg.targetMaxBpm {
                    MiniMetricPill(label: "Target", value: "\(lo)-\(hi)", icon: "scope")
                }
                if let avg = seg.averageHr {
                    MiniMetricPill(label: "Avg", value: "\(avg)", icon: "heart")
                }
                if let max = seg.maxHr {
                    MiniMetricPill(label: "Max", value: "\(max)", icon: "arrow.up")
                }
                if let pct = seg.inZonePct {
                    MiniMetricPill(label: "Zone", value: "\(pct)%", icon: "target")
                }
            }
        }
        .padding(12)
        .background(CockpitPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(kindColor(seg.kind))
                .frame(width: 4)
                .padding(.vertical, 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CockpitPalette.border)
        }
    }

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "warmup": "thermometer.sun"
        case "work": "flame.fill"
        case "recovery": "leaf.fill"
        case "cooldown": "snowflake"
        case "steady": "equal"
        default: "circle"
        }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "warmup": .orange
        case "work": .red
        case "recovery": .green
        case "cooldown": .blue
        case "steady": .purple
        default: .secondary
        }
    }

    private func kindName(_ kind: String) -> String {
        switch kind {
        case "warmup": "Warmup"
        case "work": "Work"
        case "recovery": "Recovery"
        case "cooldown": "Cooldown"
        case "steady": "Steady"
        default: kind.capitalized
        }
    }
}

private struct DetailSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(CockpitPalette.blue)
            Text(title)
                .font(.headline.weight(.bold))
            Spacer()
        }
    }
}

private struct DetailMetricGrid<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            content
        }
    }
}

private struct DetailMetricTile: View {
    let label: String
    let value: String
    let footnote: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(CockpitPalette.faint)
                .lineLimit(1)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
            Text(footnote)
                .font(.caption2.weight(.medium))
                .foregroundStyle(CockpitPalette.muted)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CockpitPalette.panelElevated.opacity(0.70), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CockpitPalette.border)
        }
    }
}

private struct MiniMetricPill: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        Label {
            Text("\(label) \(value)")
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(CockpitPalette.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(CockpitPalette.panelElevated.opacity(0.70), in: Capsule())
    }
}

private func setTypeBadge(_ type: String) -> (label: String, color: Color)? {
    SetTypeStyle.badge(type)
}

private func strengthEffortInfo(_ effort: Int) -> (label: String, color: Color) {
    switch effort {
    case 1: return ("Easy", CockpitPalette.green)
    case 2: return ("Moderate", CockpitPalette.amber)
    case 3: return ("Hard", CockpitPalette.red)
    default: return ("?", CockpitPalette.faint)
    }
}

private func cyclingEffortColor(_ effort: Int) -> Color {
    switch effort {
    case 1...3: return CockpitPalette.green
    case 4...6: return CockpitPalette.amber
    case 7...10: return CockpitPalette.red
    default: return CockpitPalette.faint
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

private func ratingLabel(_ rating: Int) -> String {
    switch rating {
    case 1: return "Easy"
    case 2: return "OK"
    case 3: return "Heavy"
    default: return "\(rating)"
    }
}

private func ratingColor(_ rating: Int) -> Color {
    switch rating {
    case 1: return CockpitPalette.green
    case 2: return CockpitPalette.blue
    case 3: return CockpitPalette.red
    default: return CockpitPalette.muted
    }
}

private func formatDuration(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return s == 0 ? "\(m) min" : "\(m):\(String(format: "%02d", s))"
}

// MARK: - Weight formatting

private func formatWeight(_ kg: Double) -> String {
    WorkoutFormatting.weight(kg)
}
