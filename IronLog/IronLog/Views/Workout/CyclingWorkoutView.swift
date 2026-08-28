import SwiftUI
import SwiftData

struct CyclingWorkoutView: View {
    @Bindable var vm: CyclingWorkoutViewModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var ticker: Timer?
    @State private var finishNotes: String = ""
    @State private var finishEffort: Int?

    var body: some View {
        Group {
            switch vm.state {
            case .idle:
                ProgressView("Loading...")
            case .running, .paused:
                runningView
            case .finishing:
                finishingView
            case .saved:
                savedView
            }
        }
        .navigationTitle("Cycling")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.state == .running || vm.state == .paused)
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
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

    // MARK: - Running

    @ViewBuilder
    private var runningView: some View {
        if let step = vm.currentStep {
            VStack(spacing: 24) {
                progressBar
                kindBadge(for: step.kind)

                // Big timer
                Text(formatTime(vm.remainingInStep))
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(vm.state == .paused ? .secondary : .primary)

                // Step name + notes
                VStack(spacing: 6) {
                    Text(step.name)
                        .font(.title2.weight(.semibold))
                    if let notes = step.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }

                // Target / live HR card
                targetCard(for: step)

                Spacer()

                // Controls
                HStack(spacing: 14) {
                    Button(action: { vm.skipStep() }) {
                        Label("Skip", systemImage: "forward.end")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: { vm.togglePause() }) {
                        Label(
                            vm.state == .paused ? "Resume" : "Pause",
                            systemImage: vm.state == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive) {
                    vm.beginFinishing()
                } label: {
                    Label("Finish workout", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var progressBar: some View {
        let total = vm.totalDurationSeconds
        let elapsed = vm.elapsedTotalSeconds
        let progress = total > 0 ? Double(elapsed) / Double(total) : 0

        return VStack(spacing: 6) {
            ProgressView(value: progress)
                .tint(.accentColor)
            HStack {
                Text("Step \(vm.currentStepIndex + 1) of \(vm.steps.count)")
                Spacer()
                Text("\(formatTime(elapsed)) / \(formatTime(total))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func kindBadge(for kind: String) -> some View {
        let (icon, color, label): (String, Color, String) = {
            switch kind {
            case "warmup":   return ("thermometer.sun", .orange, "Warmup")
            case "work":     return ("flame.fill",      .red,    "Work")
            case "recovery": return ("leaf.fill",       .green,  "Recovery")
            case "cooldown": return ("snowflake",       .blue,   "Cooldown")
            case "steady":   return ("equal",           .purple, "Steady")
            default:         return ("circle",          .secondary, kind)
            }
        }()
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func targetCard(for step: CyclingExecStep) -> some View {
        VStack(spacing: 8) {
            if step.hasHrTarget {
                Text("Target HR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(step.targetText)
                    .font(.title3.weight(.medium))

                if vm.hrSource.isAvailable {
                    Divider().padding(.vertical, 4)
                    hrCardContent
                } else {
                    Text("No heart-rate source")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if !step.targetText.isEmpty {
                Text("Target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(step.targetText)
                    .font(.title3.weight(.medium))
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func zoneColor(_ inZone: Bool?) -> Color {
        switch inZone {
        case .some(true):  return .green
        case .some(false): return .red
        case .none:        return .primary
        }
    }

    /// Above this age, we treat the sample as "not currently live" and
    /// stop displaying it as the user's headline BPM (it would mislead
    /// -- e.g. a 59 bpm resting reading from before the workout while
    /// they're cycling). We still show it in small text as "last known".
    private static let freshThresholdSeconds = 15

    /// HR card content -- either the big live BPM, or a "waiting" view
    /// with the last known reading + age, depending on freshness.
    @ViewBuilder
    private var hrCardContent: some View {
        if let bpm = vm.liveBpm, let at = vm.liveBpmSampleAt {
            let age = Int(max(0, Date.now.timeIntervalSince(at)))
            if age <= Self.freshThresholdSeconds {
                hrLiveView(bpm: bpm, ageSeconds: age)
            } else {
                hrStaleView(lastBpm: bpm, ageSeconds: age)
            }
        } else {
            // No sample at all yet (HR source on, just hasn't received).
            HStack(spacing: 6) {
                Image(systemName: "heart.text.square")
                Text("Waiting for first reading...")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func hrLiveView(bpm: Int, ageSeconds: Int) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                Text("\(bpm)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(zoneColor(vm.isInZone))

            Text(freshnessLabel(ageSeconds: ageSeconds))
                .font(.caption2)
                .foregroundStyle(freshnessColor(ageSeconds: ageSeconds))
        }
    }

    @ViewBuilder
    private func hrStaleView(lastBpm: Int, ageSeconds: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "applewatch")
                    .foregroundStyle(.orange)
                Text("Waiting for Apple Watch")
                    .font(.subheadline.weight(.medium))
            }
            Text("last reading: \(lastBpm) bpm \(freshnessLabel(ageSeconds: ageSeconds))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Tap Allow on your watch when prompted")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    /// Human-friendly "how recent is this BPM" label. The Watch typically
    /// pumps HR ~once per second during an active workout session, but
    /// Apple Health buffers and flushes batches every 2-5 s.
    private func freshnessLabel(ageSeconds age: Int) -> String {
        if age < 5 { return "live" }
        if age < 60 { return "\(age)s ago" }
        let minutes = age / 60
        return "\(minutes)m ago"
    }

    private func freshnessColor(ageSeconds age: Int) -> Color {
        if age < 10 { return .secondary }       // normal
        if age < 30 { return .orange }          // delayed but plausible
        return .red                             // likely stale (watch off wrist)
    }

    // MARK: - Finishing

    private var finishingView: some View {
        Form {
            Section("Notes") {
                TextEditor(text: $finishNotes)
                    .frame(minHeight: 80)
            }
            Section("Perceived effort") {
                Picker("Effort 1-10", selection: $finishEffort) {
                    Text("--").tag(Int?.none)
                    ForEach(1...10, id: \.self) { i in
                        Text("\(i)").tag(Int?.some(i))
                    }
                }
            }
            Section {
                Button {
                    vm.saveWorkout(
                        notes: finishNotes.trimmingCharacters(in: .whitespacesAndNewlines),
                        perceivedEffort: finishEffort
                    )
                } label: {
                    Text("Save workout")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                if vm.canCancelFinishing {
                    Button(role: .cancel) {
                        vm.cancelFinishing()
                    } label: {
                        Text("Resume")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Saved

    private var savedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Saved")
                .font(.title2.weight(.semibold))
            Button("Done") {
                vm.reset()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Helpers

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in vm.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
