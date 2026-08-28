import Foundation
import SwiftData

enum PlanImportError: LocalizedError {
    case invalidJSON(String)
    case emptyTemplates
    case duplicatePlan(String)
    case unknownPlanType(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "Invalid JSON: \(detail)"
        case .emptyTemplates:
            return "Plan must contain at least one template"
        case .duplicatePlan(let name):
            return "Plan '\(name)' already exists"
        case .unknownPlanType(let t):
            return "Unknown plan_type '\(t)'. App may need an update."
        }
    }
}

/// Either a strength or cycling plan after parse. Parse-time discriminator
/// is the top-level `plan_type` field. Both kinds can sit in the same UI.
enum ParsedPlan {
    case strength(WorkoutPlanJSON)
    case cycling(CyclingPlanJSON)

    var planType: PlanType {
        switch self {
        case .strength: return .strength
        case .cycling:  return .cycling
        }
    }

    var planName: String {
        switch self {
        case .strength(let p): return p.planName
        case .cycling(let p):  return p.planName
        }
    }

    var planVersion: Int {
        switch self {
        case .strength(let p): return p.planVersion
        case .cycling(let p):  return p.planVersion
        }
    }

    var author: String? {
        switch self {
        case .strength(let p): return p.author
        case .cycling(let p):  return p.author
        }
    }

    var notes: String? {
        switch self {
        case .strength(let p): return p.notes
        case .cycling(let p):  return p.notes
        }
    }

    var templateCount: Int {
        switch self {
        case .strength(let p): return p.templates.count
        case .cycling(let p):  return p.templates.count
        }
    }
}

/// Lightweight envelope: peek `plan_type` before deciding which full schema
/// to decode. Useful for both raw clipboard JSON and per-item server payload.
private struct PlanTypeEnvelope: Codable {
    let planType: String
    enum CodingKeys: String, CodingKey { case planType = "plan_type" }
}

final class PlanImportService {

    // MARK: - Parse JSON into ParsedPlan (auto-dispatches by plan_type)

    static func parse(_ jsonString: String) throws -> ParsedPlan {
        guard let data = jsonString.data(using: .utf8) else {
            throw PlanImportError.invalidJSON("Failed to read string as UTF-8")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ParsedPlan {
        // 1. Peek plan_type
        let envelope: PlanTypeEnvelope
        do {
            envelope = try JSONDecoder().decode(PlanTypeEnvelope.self, from: data)
        } catch let error as DecodingError {
            throw PlanImportError.invalidJSON(error.friendlyDescription)
        } catch {
            throw PlanImportError.invalidJSON(error.localizedDescription)
        }

        // 2. Dispatch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeISO8601)

        switch envelope.planType {
        case PlanType.strength.rawValue:
            let plan: WorkoutPlanJSON
            do {
                plan = try decoder.decode(WorkoutPlanJSON.self, from: data)
            } catch let error as DecodingError {
                throw PlanImportError.invalidJSON(error.friendlyDescription)
            }
            guard !plan.templates.isEmpty else { throw PlanImportError.emptyTemplates }
            return .strength(plan)

        case PlanType.cycling.rawValue:
            let plan: CyclingPlanJSON
            do {
                plan = try decoder.decode(CyclingPlanJSON.self, from: data)
            } catch let error as DecodingError {
                throw PlanImportError.invalidJSON(error.friendlyDescription)
            }
            guard !plan.templates.isEmpty else { throw PlanImportError.emptyTemplates }
            return .cycling(plan)

        default:
            throw PlanImportError.unknownPlanType(envelope.planType)
        }
    }

    // MARK: - Import into SwiftData (dispatches)

    @MainActor
    static func importPlan(
        _ parsed: ParsedPlan,
        into context: ModelContext,
        replaceExisting: Bool = false
    ) throws {
        switch parsed {
        case .strength(let json):
            _ = try importStrength(json, into: context, replaceExisting: replaceExisting)
        case .cycling(let json):
            _ = try importCycling(json, into: context, replaceExisting: replaceExisting)
        }
    }

    // MARK: - Strength import

    @MainActor
    static func importStrength(
        _ json: WorkoutPlanJSON,
        into context: ModelContext,
        replaceExisting: Bool = false
    ) throws -> SDPlan {
        let jsonPlanId = json.planId
        let jsonPlanType = json.planType.rawValue
        let jsonPlanName = json.planName
        let descriptor: FetchDescriptor<SDPlan>
        if jsonPlanId.isEmpty {
            descriptor = FetchDescriptor<SDPlan>(
                predicate: #Predicate {
                    $0.planType == jsonPlanType
                    && $0.planId == ""
                    && $0.planName == jsonPlanName
                }
            )
        } else {
            descriptor = FetchDescriptor<SDPlan>(
                predicate: #Predicate {
                    $0.planType == jsonPlanType && (
                        $0.planId == jsonPlanId
                        || ($0.planId == "" && $0.planName == jsonPlanName)
                    )
                }
            )
        }
        let existing = try context.fetch(descriptor)

        if !existing.isEmpty {
            guard replaceExisting else {
                throw PlanImportError.duplicatePlan(json.planName)
            }
            // The predicate also matches the legacy `planId == ""` row, so
            // there can be more than one; leaving any behind would break the
            // "one plan per (plan_type, plan_id)" invariant.
            for old in existing {
                context.delete(old)
            }
        }

        let plan = SDPlan(
            planType: json.planType.rawValue,
            planId: json.planId,
            planName: json.planName,
            planVersion: json.planVersion,
            schema: json.schema,
            createdAt: json.createdAt,
            author: json.author,
            notes: json.notes
        )
        context.insert(plan)

        for (tIdx, tJSON) in json.templates.enumerated() {
            let template = SDTemplate(
                templateId: tJSON.id,
                name: tJSON.name,
                notes: tJSON.notes,
                sortOrder: tIdx
            )
            template.plan = plan

            for (gIdx, gJSON) in tJSON.groups.enumerated() {
                let group = SDExerciseGroup(
                    name: gJSON.name,
                    sortOrder: gIdx
                )
                group.template = template

                for (eIdx, eJSON) in gJSON.exercises.enumerated() {
                    let exercise = SDExercise(
                        exerciseId: eJSON.id,
                        catalogId: eJSON.catalogId,
                        name: eJSON.name,
                        bodyPart: eJSON.bodyPart.rawValue,
                        equipment: eJSON.equipment?.rawValue,
                        restSeconds: eJSON.restSeconds ?? 90,
                        technique: eJSON.technique?.rawValue ?? "straight",
                        supersetWith: eJSON.supersetWith,
                        tempo: eJSON.tempo,
                        notes: eJSON.notes,
                        stretchFocus: eJSON.stretchFocus ?? false,
                        sortOrder: eIdx,
                        maxMiniSets: eJSON.maxMiniSets
                    )
                    exercise.group = group

                    for (sIdx, sJSON) in eJSON.sets.enumerated() {
                        let set = SDPrescribedSet(
                            type: sJSON.type?.rawValue ?? "working",
                            reps: sJSON.reps,
                            weightKg: sJSON.weightKg,
                            rir: sJSON.rir,
                            weightPercentDrop: sJSON.weightPercentDrop,
                            sortOrder: sIdx
                        )
                        set.exercise = exercise
                    }
                }
            }
        }

        return plan
    }

    // MARK: - Cycling import

    @MainActor
    static func importCycling(
        _ json: CyclingPlanJSON,
        into context: ModelContext,
        replaceExisting: Bool = false
    ) throws -> SDCyclingPlan {
        let planId = json.planId
        let planName = json.planName
        let descriptor: FetchDescriptor<SDCyclingPlan>
        if planId.isEmpty {
            descriptor = FetchDescriptor<SDCyclingPlan>(
                predicate: #Predicate {
                    $0.planId == "" && $0.planName == planName
                }
            )
        } else {
            descriptor = FetchDescriptor<SDCyclingPlan>(
                predicate: #Predicate {
                    $0.planId == planId
                    || ($0.planId == "" && $0.planName == planName)
                }
            )
        }
        let existing = try context.fetch(descriptor)

        if !existing.isEmpty {
            guard replaceExisting else {
                throw PlanImportError.duplicatePlan(json.planName)
            }
            for old in existing {
                context.delete(old)
            }
        }

        let plan = SDCyclingPlan(
            planId: json.planId,
            planName: json.planName,
            planVersion: json.planVersion,
            schema: json.schema,
            createdAt: json.createdAt,
            author: json.author,
            notes: json.notes,
            maxHrBpm: json.maxHrBpm
        )
        context.insert(plan)

        for (tIdx, tJSON) in json.templates.enumerated() {
            let template = SDCyclingTemplate(
                templateId: tJSON.id,
                name: tJSON.name,
                equipment: tJSON.equipment?.rawValue,
                notes: tJSON.notes,
                sortOrder: tIdx
            )
            if let prog = tJSON.progression {
                template.progressionAxis = prog.axis?.rawValue
                template.progressionAdvanceWhen = prog.advanceWhen
                if let step = prog.step {
                    template.progressionStepIntervalsDelta = step.intervalsDelta
                    template.progressionStepWorkDurationSeconds = step.workDurationSeconds
                    template.progressionStepHrBpmDelta = step.hrBpmDelta
                }
            }
            template.plan = plan

            for (sIdx, sJSON) in tJSON.segments.enumerated() {
                let segment = makeCyclingSegment(sJSON, sortOrder: sIdx)
                segment.template = template

                if sJSON.kind == .intervalBlock {
                    for (cIdx, cJSON) in (sJSON.children ?? []).enumerated() {
                        let child = makeCyclingSegment(cJSON, sortOrder: cIdx)
                        child.parent = segment
                    }
                }
            }
        }

        return plan
    }

    @MainActor
    private static func makeCyclingSegment(
        _ json: CyclingSegmentJSON,
        sortOrder: Int
    ) -> SDCyclingSegment {
        SDCyclingSegment(
            sortOrder: sortOrder,
            kind: json.kind.rawValue,
            name: json.name,
            notes: json.notes,
            durationSeconds: json.durationSeconds,
            targetType: json.target?.type.rawValue,
            targetMin: json.target?.min,
            targetMax: json.target?.max,
            targetZoneLabel: json.target?.zoneLabel,
            repeats: json.repeats
        )
    }
}

// MARK: - DecodingError helper

extension DecodingError {
    var friendlyDescription: String {
        switch self {
        case .keyNotFound(let key, let ctx):
            return "Missing key '\(key.stringValue)' at \(ctx.codingPath.pathString)"
        case .typeMismatch(let type, let ctx):
            return "Type mismatch for \(type) at \(ctx.codingPath.pathString)"
        case .valueNotFound(let type, let ctx):
            return "Null value for \(type) at \(ctx.codingPath.pathString)"
        case .dataCorrupted(let ctx):
            return "Corrupted data at \(ctx.codingPath.pathString)"
        @unknown default:
            return localizedDescription
        }
    }
}

private extension [CodingKey] {
    var pathString: String {
        map(\.stringValue).joined(separator: ".")
    }
}

// MARK: - Date decoding

/// `JSONDecoder.iso8601` only understands `[.withInternetDateTime]`, so a
/// timestamp carrying fractional seconds -- what Python's `datetime.isoformat()`
/// produces, and what `CrashReporter` itself emits -- would reject the whole
/// plan over its `created_at` field.
private let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func decodeISO8601(_ decoder: Decoder) throws -> Date {
    let raw = try decoder.singleValueContainer().decode(String.self)
    if let date = iso8601Plain.date(from: raw) { return date }
    if let date = iso8601WithFractionalSeconds.date(from: raw) { return date }
    throw DecodingError.dataCorrupted(
        .init(
            codingPath: decoder.codingPath,
            debugDescription: "Expected an ISO 8601 date, got \"\(raw)\""
        )
    )
}
