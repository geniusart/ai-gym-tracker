import ActivityKit
import SwiftUI
import WidgetKit

struct RestTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestTimerAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.exerciseName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        if isPerformingPhase(context) {
                            if let w = context.state.weightKg, w > 0 {
                                Text("\(formatWeight(w)) kg")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else if !context.state.nextSetLabel.isEmpty {
                            Text(context.state.nextSetLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerView(context: context)
                        .font(.title2.weight(.medium).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if isPerformingPhase(context) {
                        Text("Working set")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        if context.state.isOvertime {
                            Text("GO!")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.yellow)
                        } else {
                            ProgressView(
                                timerInterval: Date.now...max(Date.now, context.state.timerDate),
                                countsDown: true
                            )
                            .tint(.blue)
                        }
                    }
                }
            } compactLeading: {
                // During a working set: icon + weight here, set stopwatch on
                // trailing -- no duplication. While resting: just the timer
                // icon (countdown is on the trailing).
                HStack(spacing: 4) {
                    Image(systemName: isPerformingPhase(context) ? "dumbbell.fill" : "timer")
                        .foregroundStyle(accentColor(context: context))
                    if isPerformingPhase(context),
                       let w = context.state.weightKg, w > 0 {
                        Text("\(formatWeight(w)) kg")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactTrailing: {
                timerView(context: context)
                    .font(.caption.weight(.bold).monospacedDigit())
            } minimal: {
                Image(systemName: isPerformingPhase(context) ? "dumbbell.fill" : "timer")
                    .foregroundStyle(accentColor(context: context))
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(
        context: ActivityViewContext<RestTimerAttributes>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.exerciseName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if isPerformingPhase(context) {
                    if let w = context.state.weightKg, w > 0 {
                        Text("\(formatWeight(w)) kg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(context.state.nextSetLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            timerView(context: context)
                .font(.title.weight(.medium).monospacedDigit())
        }
        .padding()
        .background(.black)
    }

    // MARK: - Timer

    @ViewBuilder
    private func timerView(
        context: ActivityViewContext<RestTimerAttributes>
    ) -> some View {
        if isPerformingPhase(context) {
            // Set is in progress: show how long the user has been performing
            // it. SwiftUI's `Text(timerInterval:)` ticks on its own without
            // pushing updates from the host app -- so the countdown keeps
            // running even when IronLog is fully backgrounded.
            // `timerDate` here is the start-of-set wall-clock time.
            Text(
                timerInterval: context.state.timerDate...Date.distantFuture,
                countsDown: false,
                showsHours: false
            )
            .fontWeight(.bold)
            .foregroundStyle(.green)
        } else if context.state.isOvertime {
            // Overtime: clear call to action
            Text("GO!")
                .fontWeight(.bold)
                .foregroundStyle(.yellow)
        } else {
            // Resting: normal countdown
            Text(
                timerInterval: Date.now...max(Date.now, context.state.timerDate),
                countsDown: true
            )
        }
    }

    // MARK: - Helpers

    private func isPerformingPhase(
        _ context: ActivityViewContext<RestTimerAttributes>
    ) -> Bool {
        context.state.phase == "performing"
    }

    private func accentColor(
        context: ActivityViewContext<RestTimerAttributes>
    ) -> Color {
        if isPerformingPhase(context) { return .green }
        return context.state.isOvertime ? .yellow : .blue
    }
}

private func formatWeight(_ kg: Double) -> String {
    WorkoutFormatting.weight(kg)
}
