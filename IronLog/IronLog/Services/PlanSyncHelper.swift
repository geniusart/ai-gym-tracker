import Foundation
import SwiftData

enum PlanSyncHelper {

    private static let throttleInterval: TimeInterval = 600 // 10 min
    private(set) static var lastSyncDate: Date?

    /// Sync if enough time has passed since the last auto-sync.
    /// Pull-to-refresh calls bypass throttle by passing `force: true`.
    @discardableResult
    @MainActor
    static func syncIfNeeded(
        context: ModelContext,
        force: Bool = false
    ) async -> Error? {
        guard SyncService.isConfigured else {
            return force ? SyncError.noServerURL : nil
        }
        guard SyncService.isAuthenticated else {
            return force ? SyncError.notAuthenticated : nil
        }
        if !force,
           let last = lastSyncDate,
           Date.now.timeIntervalSince(last) < throttleInterval {
            return nil
        }
        return await sync(context: context)
    }

    @discardableResult
    @MainActor
    static func sync(context: ModelContext) async -> Error? {
        guard SyncService.isConfigured else { return SyncError.noServerURL }
        guard SyncService.isAuthenticated else { return SyncError.notAuthenticated }
        // Claim the throttle window before suspending. Setting it afterwards
        // let every caller that started during the round trip pass the guard,
        // so a cold launch fired `GET /plans` two or three times over.
        let previousSyncDate = lastSyncDate
        lastSyncDate = .now
        do {
            let summaries = try await SyncService.fetchPlans()
            var firstImportError: Error?
            for summary in summaries {
                if let error = importIfNewer(summary, context: context),
                   firstImportError == nil {
                    firstImportError = error
                }
            }
            return firstImportError
        } catch {
            // The round trip failed, so nothing was refreshed -- let the next
            // caller retry instead of holding the window for 10 minutes.
            lastSyncDate = previousSyncDate
            return error
        }
    }

    /// Import a plan if the local copy is missing or has a lower version.
    /// Dispatches by `plan_type`; unknown types are skipped silently
    /// (the user will see the plan via the server's web UI / next app update).
    @MainActor
    private static func importIfNewer(
        _ summary: SyncService.PlanSummary,
        context: ModelContext
    ) -> Error? {
        switch summary.planType {
        case PlanType.strength.rawValue:
            return importIfNewerStrength(summary, context: context)
        case PlanType.cycling.rawValue:
            return importIfNewerCycling(summary, context: context)
        default:
            // unknown plan type -- a newer build will handle it
            return nil
        }
    }

    @MainActor
    private static func importIfNewerStrength(
        _ summary: SyncService.PlanSummary,
        context: ModelContext
    ) -> Error? {
        let planId = summary.planId
        let descriptor = FetchDescriptor<SDPlan>(
            predicate: #Predicate { $0.planId == planId }
        )
        // A failed fetch must not read as "no local plan" -- that would let a
        // `replaceExisting` import overwrite a newer local copy.
        guard let matches = try? context.fetch(descriptor) else {
            return SyncError.planFetchFailed(planId)
        }
        if let existing = matches.max(by: { $0.planVersion < $1.planVersion }),
           existing.planVersion >= summary.planVersion {
            return nil
        }
        do {
            guard case .strength(let json) = try PlanImportService.parse(summary.rawJSON) else {
                return PlanImportError.unknownPlanType(summary.planType)
            }
            _ = try PlanImportService.importStrength(
                json,
                into: context,
                replaceExisting: true
            )
            return nil
        } catch {
            // Surfaced by the caller: silently dropping this made a plan the
            // app cannot decode simply never appear, with no diagnostic.
            return error
        }
    }

    @MainActor
    private static func importIfNewerCycling(
        _ summary: SyncService.PlanSummary,
        context: ModelContext
    ) -> Error? {
        let planId = summary.planId
        let descriptor = FetchDescriptor<SDCyclingPlan>(
            predicate: #Predicate { $0.planId == planId }
        )
        // A failed fetch must not read as "no local plan" -- that would let a
        // `replaceExisting` import overwrite a newer local copy.
        guard let matches = try? context.fetch(descriptor) else {
            return SyncError.planFetchFailed(planId)
        }
        if let existing = matches.max(by: { $0.planVersion < $1.planVersion }),
           existing.planVersion >= summary.planVersion {
            return nil
        }
        do {
            guard case .cycling(let json) = try PlanImportService.parse(summary.rawJSON) else {
                return PlanImportError.unknownPlanType(summary.planType)
            }
            _ = try PlanImportService.importCycling(
                json,
                into: context,
                replaceExisting: true
            )
            return nil
        } catch {
            // Surfaced by the caller: silently dropping this made a plan the
            // app cannot decode simply never appear, with no diagnostic.
            return error
        }
    }
}
