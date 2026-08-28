import Foundation

// MARK: - Workout Plan (import schema mirror)

struct WorkoutPlanJSON: Codable {
    let planType: PlanType
    let planId: String
    let planName: String
    let planVersion: Int
    let schema: String
    let createdAt: Date
    let author: String?
    let notes: String?
    let templates: [TemplateJSON]

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case planId = "plan_id"
        case planName = "plan_name"
        case planVersion = "plan_version"
        case schema
        case createdAt = "created_at"
        case author
        case notes
        case templates
    }
}

struct TemplateJSON: Codable {
    let id: String
    let name: String
    let notes: String?
    let groups: [ExerciseGroupJSON]
}

struct ExerciseGroupJSON: Codable {
    let name: String
    let exercises: [ExerciseJSON]
}

struct ExerciseJSON: Codable {
    let id: String
    let catalogId: String?
    let name: String
    let bodyPart: BodyPart
    let equipment: Equipment?
    let sets: [PrescribedSetJSON]
    let restSeconds: Int?
    let technique: Technique?
    let supersetWith: String?
    let tempo: String?
    let notes: String?
    let stretchFocus: Bool?
    let maxMiniSets: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case catalogId = "catalog_id"
        case bodyPart = "body_part"
        case equipment, sets
        case restSeconds = "rest_seconds"
        case technique
        case supersetWith = "superset_with"
        case tempo, notes
        case stretchFocus = "stretch_focus"
        case maxMiniSets = "max_mini_sets"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
        name = try c.decode(String.self, forKey: .name)
        bodyPart = try c.decode(BodyPart.self, forKey: .bodyPart)
        equipment = try c.decodeIfKnown(Equipment.self, forKey: .equipment)
        sets = try c.decode([PrescribedSetJSON].self, forKey: .sets)
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        technique = try c.decodeIfPresent(Technique.self, forKey: .technique)
        supersetWith = try c.decodeIfPresent(String.self, forKey: .supersetWith)
        tempo = try c.decodeIfPresent(String.self, forKey: .tempo)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        stretchFocus = try c.decodeIfPresent(Bool.self, forKey: .stretchFocus)
        maxMiniSets = try c.decodeIfPresent(Int.self, forKey: .maxMiniSets)
    }
}

struct PrescribedSetJSON: Codable {
    let type: SetType?
    let reps: Int?
    let weightKg: Double?
    let rir: Int?
    let weightPercentDrop: Double?

    enum CodingKeys: String, CodingKey {
        case type, reps, rir
        case weightKg = "weight_kg"
        case weightPercentDrop = "weight_percent_drop"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfKnown(SetType.self, forKey: .type)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg)
        rir = try c.decodeIfPresent(Int.self, forKey: .rir)
        weightPercentDrop = try c.decodeIfPresent(
            Double.self, forKey: .weightPercentDrop
        )
    }
}

// MARK: - Enums

enum BodyPart: String, Codable {
    case chest, back, shoulders, legs, arms, core
    case fullBody = "full_body"
}

enum Equipment: String, Codable {
    case machine, barbell, dumbbell, cable, bodyweight
    case plateLoaded = "plate_loaded"
    case smithMachine = "smith_machine"
    case other
}

enum SetType: String, Codable {
    case warmup, working, drop, backoff
}

/// Decoding helper for the optional descriptive enums. The server validates
/// `body_part` and `technique` but not `equipment` or `sets[].type`, so a plan
/// carrying a value this build does not know about is accepted upstream and
/// would otherwise throw here -- rejecting the whole plan, every template, over
/// one cosmetic field.
extension KeyedDecodingContainer {
    func decodeIfKnown<T: RawRepresentable & Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? where T.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return T(rawValue: raw)
    }
}

enum Technique: String, Codable {
    case straight
    case dropSet = "drop_set"
    case restPause = "rest_pause"
    case myoReps = "myo_reps"
    case superset
}
