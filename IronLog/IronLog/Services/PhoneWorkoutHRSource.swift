import Foundation
import HealthKit

/// HR source that runs an `HKWorkoutSession` directly on the iPhone (iOS 26+).
///
/// Why this exists:
/// - `HealthKitHRSource` (passive observer) sees only what watch apps choose
///   to push to Health -- and Apple Fitness specifically buffers HR samples
///   for tens of seconds before flushing, which makes "live HR" useless.
/// - The native cycling Workout API on iPhone (introduced in iOS 26) lets
///   us own the session ourselves. The paired Apple Watch automatically
///   joins as the HR source, and `HKLiveWorkoutBuilder` delivers samples
///   ~1 Hz with no buffering. No need for Apple Fitness, no need for
///   IronLogWatch -- just open IronLog cycling and the watch lights up.
///
/// On iOS < 26 (or if session creation fails), `HRSourceResolver` falls
/// back to `HealthKitHRSource`.
@available(iOS 26.0, *)
@MainActor
final class PhoneWorkoutHRSource: NSObject, HRSource {

    private let store = HKHealthStore()
    private let bpmUnit = HKUnit(from: "count/min")
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var currentBpm: Int?
    private(set) var lastSampleAt: Date?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func start() {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .indoor

        do {
            let session = try HKWorkoutSession(
                healthStore: store, configuration: config
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store, workoutConfiguration: config
            )

            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            session.startActivity(with: .now)
            builder.beginCollection(withStart: .now) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    self?.session?.end()
                    self?.session = nil
                    self?.builder = nil
                    self?.currentBpm = nil
                    self?.lastSampleAt = nil
                    print("PhoneWorkoutHRSource beginCollection failed: \(error.localizedDescription)")
                }
            }
        } catch {
            // Session creation failed (auth denied, simulator, etc.).
            // Resolver will not retry; UI shows "No heart-rate source".
        }
    }

    func stop() {
        guard let session, let builder else { return }

        // Clear the handles before the async teardown: `saveWorkout` stops the
        // source and the `.saved` transition stops it again a frame later, so
        // waiting for `finishWorkout` would re-end the same builder.
        self.session = nil
        self.builder = nil

        session.end()
        builder.endCollection(withEnd: .now) { _, _ in
            // Save the workout to Apple Health so the user gets Activity-ring
            // credit and the HR samples persist alongside other workouts.
            // If the user ever doesn't want this, we can switch to discard.
            builder.finishWorkout { _, _ in }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

@available(iOS 26.0, *)
extension PhoneWorkoutHRSource: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _: HKWorkoutSession,
        didChangeTo _: HKWorkoutSessionState,
        from _: HKWorkoutSessionState,
        date _: Date
    ) {}

    nonisolated func workoutSession(
        _: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.session = nil
            self?.builder = nil
            self?.currentBpm = nil
            self?.lastSampleAt = nil
            print("PhoneWorkoutHRSource session failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

@available(iOS 26.0, *)
extension PhoneWorkoutHRSource: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let bpm = stats.mostRecentQuantity()?.doubleValue(
                for: HKUnit(from: "count/min")
              )
        else { return }

        let endDate = stats.mostRecentQuantityDateInterval()?.end ?? .now
        let value = Int(bpm.rounded())
        Task { @MainActor [weak self] in
            guard value > 0 else { return }
            self?.currentBpm = value
            self?.lastSampleAt = endDate
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_: HKLiveWorkoutBuilder) {}
}
