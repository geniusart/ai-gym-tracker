import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen Live Activity for a cycling workout.
///
/// The widget receives the **full schedule** of all segments (with absolute
/// end-times) and computes the active segment by comparing `endsAt` to
/// `Date.now`, so any re-render lands on the right segment.
///
/// It does NOT advance on its own: `Text(timerInterval:)` is a self-updating
/// leaf the system ticks from an already-rendered view, and reaching its end
/// does not re-run this closure. Only a re-render moves the banner on -- a
/// content push from the host, the `staleDate` the host sets to the current
/// segment's end, a screen wake, or a Dynamic Island expand.
struct CyclingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CyclingActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    let current = currentSegment(of: context.state)
                    let kind = current?.stepKind ?? "bicycle"
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: kindIcon(kind))
                                .foregroundStyle(kindColor(kind))
                            Text(current?.stepName ?? "Done")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        if let current {
                            Text("Step \(current.stepIndex + 1) of \(context.attributes.totalSteps)")
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
                    let current = currentSegment(of: context.state)
                    let next = nextSegment(of: context.state)
                    VStack(spacing: 4) {
                        if !context.state.paused, let current {
                            ProgressView(
                                timerInterval: Date.now...max(Date.now, current.endsAt),
                                countsDown: true,
                                label: { EmptyView() },
                                currentValueLabel: { EmptyView() }
                            )
                            .tint(kindColor(current.stepKind))
                        }
                        if let next {
                            Text("Next: \(next.stepName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                let kind = currentSegment(of: context.state)?.stepKind ?? "bicycle"
                Image(systemName: kindIcon(kind))
                    .foregroundStyle(kindColor(kind))
            } compactTrailing: {
                timerView(context: context)
                    .font(.caption.weight(.bold).monospacedDigit())
            } minimal: {
                let kind = currentSegment(of: context.state)?.stepKind ?? "bicycle"
                Image(systemName: kindIcon(kind))
                    .foregroundStyle(kindColor(kind))
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenView(
        context: ActivityViewContext<CyclingActivityAttributes>
    ) -> some View {
        let current = currentSegment(of: context.state)
        let next = nextSegment(of: context.state)

        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: kindIcon(current?.stepKind ?? "bicycle"))
                    .foregroundStyle(kindColor(current?.stepKind ?? "bicycle"))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.stepName ?? "Done")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let current {
                        Text("Step \(current.stepIndex + 1) of \(context.attributes.totalSteps) -- \(context.attributes.workoutName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                timerView(context: context)
                    .font(.title.weight(.medium).monospacedDigit())
            }

            if !context.state.paused, let current {
                ProgressView(
                    timerInterval: Date.now...max(Date.now, current.endsAt),
                    countsDown: true,
                    label: { EmptyView() },
                    currentValueLabel: { EmptyView() }
                )
                .tint(kindColor(current.stepKind))
            }

            if let next {
                HStack {
                    Text("Next: \(next.stepName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(.black)
    }

    // MARK: - Timer

    @ViewBuilder
    private func timerView(
        context: ActivityViewContext<CyclingActivityAttributes>
    ) -> some View {
        if context.state.paused {
            Text("Paused")
                .foregroundStyle(.secondary)
        } else if let current = currentSegment(of: context.state) {
            Text(
                timerInterval: Date.now...max(Date.now, current.endsAt),
                countsDown: true
            )
            .foregroundStyle(kindColor(current.stepKind))
        } else {
            Text("Done")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Schedule helpers (computed from state + Date.now)

    private func currentSegment(
        of state: CyclingActivityAttributes.ContentState
    ) -> ScheduledSegment? {
        let now = Date.now
        return state.schedule.first(where: { $0.endsAt > now })
    }

    private func nextSegment(
        of state: CyclingActivityAttributes.ContentState
    ) -> ScheduledSegment? {
        let now = Date.now
        guard let currentIdx = state.schedule.firstIndex(where: { $0.endsAt > now }),
              currentIdx + 1 < state.schedule.count
        else { return nil }
        return state.schedule[currentIdx + 1]
    }

    // MARK: - Kind helpers

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "warmup":   return "thermometer.sun"
        case "work":     return "flame.fill"
        case "recovery": return "leaf.fill"
        case "cooldown": return "snowflake"
        case "steady":   return "equal"
        default:         return "bicycle"
        }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "warmup":   return .orange
        case "work":     return .red
        case "recovery": return .green
        case "cooldown": return .blue
        case "steady":   return .purple
        default:         return .accentColor
        }
    }
}
