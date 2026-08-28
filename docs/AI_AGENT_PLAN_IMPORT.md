# IronLog Plan Import Instructions for AI Agents

This document is the contract for AI agents that generate IronLog plan JSON for import into the server.

Production API base URL:

```text
https://v170184.hosted-by-vdsina.com
```

Use relative paths when running against another IronLog server.

## Instruction Endpoint

The latest plan-import instructions are served by the API:

```text
GET /agent-instructions/plan-import
GET /agent-instructions/plan-import.json
```

Production URLs:

```text
https://v170184.hosted-by-vdsina.com/agent-instructions/plan-import
https://v170184.hosted-by-vdsina.com/agent-instructions/plan-import.json
```

The server stores the editable instruction text in MongoDB. The repository file is only the initial fallback for fresh deployments. Operators can update the instruction without redeploying the container:

```text
PUT /agent-instructions/plan-import
Authorization: Bearer <JWT>
Content-Type: application/json
```

This write is admin-only: the token's email must be listed in the server's
`ADMIN_EMAILS` setting, or the user document must carry `is_admin: true`.
The matching GET is unauthenticated, so anyone able to write here could feed
arbitrary instructions to every agent that reads them.

Body:

```json
{
  "content": "# Updated instructions...",
  "title": "IronLog Plan Import Instructions for AI Agents"
}
```

## Goal

Convert a user's training prescription into a valid IronLog plan JSON, then upload it with `PUT /plan`.

The server supports two plan types:

- `strength`: gym/resistance plans with exercises, sets, reps, RIR, weights, rest timers, and techniques.
- `cycling`: bike/cardio plans with timed segments, HR/RPE targets, and interval blocks.

Do not mix plan types in one JSON document.

## Required Live References

Always request live references before generating a plan. These references can change over time, so do not rely on memorized or previously cached copies.

Plan schemas:

```text
GET /schema
GET /schema?type=strength
GET /schema?type=cycling
```

Production URLs:

```text
https://v170184.hosted-by-vdsina.com/schema
https://v170184.hosted-by-vdsina.com/schema?type=strength
https://v170184.hosted-by-vdsina.com/schema?type=cycling
```

Strength exercise catalog:

```text
GET /exercises/catalog?plan_type=strength
GET /exercises/{slug}
GET /exercises/{slug}/docs?locale=ru
GET /exercise-docs/missing?locale=ru&status=reviewed
```

Production URLs:

```text
https://v170184.hosted-by-vdsina.com/exercises/catalog?plan_type=strength
https://v170184.hosted-by-vdsina.com/exercises/{slug}
https://v170184.hosted-by-vdsina.com/exercises/{slug}/docs?locale=ru
https://v170184.hosted-by-vdsina.com/exercise-docs/missing?locale=ru&status=reviewed
```

Muscle group reference:

```text
GET /muscle-groups
GET /muscle-groups?region=legs
GET /muscle-groups/{slug}
```

Production URLs:

```text
https://v170184.hosted-by-vdsina.com/muscle-groups
https://v170184.hosted-by-vdsina.com/muscle-groups?region=legs
https://v170184.hosted-by-vdsina.com/muscle-groups/{slug}
```

Plan upload and existing versions require JWT auth:

```text
GET /plans
GET /plans?type=strength
GET /plans?type=cycling
PUT /plan
```

Use:

```text
Authorization: Bearer <JWT>
Content-Type: application/json
```

## Common Plan Fields

Every generated plan must include:

- `plan_type`: exactly `strength` or `cycling`.
- `plan_id`: stable lowercase kebab-case slug for the logical plan.
- `plan_version`: positive integer version.
- `plan_name`: user-facing display name.
- `schema`: copy the selected schema's `x-schema-id`.
- `created_at`: current ISO 8601 UTC timestamp.
- `author`: optional creator identifier, such as `ai-agent`.
- `notes`: concise plan-level notes, goals, constraints, progression rules, and safety considerations.
- `templates`: non-empty array.

Do not include comments in JSON. Use numbers as JSON numbers, not strings.

## Plan Version Rules

Before uploading a plan, fetch existing plans for the same user:

```text
GET /plans?type=<plan_type>
```

Find a plan with the same `plan_id` and `plan_type`.

For a new logical plan:

- Choose a new stable `plan_id`.
- Set `plan_version` to `1`.

For an update to an existing logical plan:

- Keep the same `plan_id`.
- Set `plan_version` to `latest_plan_version + 1`.
- Keep stable IDs inside the plan when they still refer to the same item:
  - strength `template.id`
  - strength `exercise.id`
  - cycling `template.id`

Do not create a new `plan_id` for normal progression changes:

- weight/reps/set changes
- exercise substitutions inside the same training goal
- deloads
- progression blocks
- template renames
- notes/coaching changes
- changing `plan_name`

Create a new `plan_id` only when the plan is a separate logical program:

- different training modality
- different high-level goal
- different user constraints
- a separate plan the user should keep alongside the old one
- explicit user request to create a new plan

If `PUT /plan` returns `409`, fetch latest plans again and retry only after increasing `plan_version`.

## Strength Plan Generation

Use the strength schema:

```text
GET /schema?type=strength
```

Strength structure:

```text
templates[] -> groups[] -> exercises[] -> sets[]
```

Before generating exercises, fetch the live catalog:

```text
GET /exercises/catalog?plan_type=strength
```

The catalog is the source of truth for exercise identity. Each strength exercise should include:

```json
"catalog_id": "<catalog slug>"
```

The server may accept a strength exercise without `catalog_id`, but it will return `_warnings`, and analytics continuity may break.

### Strength Catalog Matching

For every intended exercise:

1. Translate the user's exercise phrase to English internally if needed.
2. Match against the live catalog fields:
   - `slug`
   - `name`
   - `aliases`
   - `equipment`
   - `movement_pattern`
   - `primary_muscles`
   - `secondary_muscles`
   - `body_part`
3. Prefer exact `name` or `aliases` matches.
4. If multiple matches remain, prefer matching `equipment`.
5. If still ambiguous, prefer matching `movement_pattern` and primary muscles.
6. If still ambiguous, ask the user instead of guessing.

When a catalog match is found:

- Set `catalog_id` to the matched `slug`.
- Set plan exercise `body_part` to catalog `body_part`.
- Set plan exercise `equipment` to catalog `equipment`.
- The plan exercise `name` may be localized for the user.

Do not invent `catalog_id`.

### Exercise Documentation Reference

After matching a strength exercise to `catalog_id`, fetch:

```text
GET /exercises/{catalog_id}/docs?locale=ru
```

Use this reference for execution notes, safety notes, common mistakes, and
exercise-specific wording. If it returns 404, continue generating the plan from
the catalog and schema, but do not invent a permanent documentation card. To
find documentation gaps:

```text
GET /exercise-docs/missing?locale=ru&status=reviewed
```

Documentation records are a separate reference layer from the exercise catalog.
They are not part of the plan JSON schema today. Do not embed long technique
instructions into plan exercises unless the user explicitly asks for coaching
notes in the plan.

### Missing Strength Exercises

If the required exercise is not in the catalog:

1. Propose a new catalog entry.
2. Ask the user for confirmation.
3. Only after confirmation, create it with:

```text
POST /exercises/catalog
```

The payload must reference existing muscle group slugs from:

```text
GET /muscle-groups
```

Suggested exercise slug format:

```text
<movement>_<equipment>_<modifier?>
```

Examples:

- `leg_press_machine`
- `chest_press_machine`
- `lat_pulldown_cable_wide`
- `cable_triceps_pushdown_rope`

Never rename an existing slug. If an exercise meaning changes, deprecate the old slug and create a new one.

### Strength Exercise IDs

`exercise.id` is not the same as `catalog_id`.

- `exercise.id`: local stable ID inside a plan, e.g. `a1`, `b3`.
- `catalog_id`: global exercise catalog slug, e.g. `leg_press_machine`.

Keep `exercise.id` stable across versions when it represents the same exercise in the same plan.

## Strength Technique Mapping

Use these exact technique values:

- `straight`
- `drop_set`
- `rest_pause`
- `myo_reps`
- `superset`

Rules:

- Normal exercise: `technique: "straight"`.
- Drop set: use a working set followed by a `drop` set with `weight_percent_drop`.
- Rest-pause: use `technique: "rest_pause"` and working sets.
- Myo-reps: provide only the activation set; the app generates mini-sets. Set `max_mini_sets` when needed.
- Superset: both paired exercises must use `technique: "superset"` and reference each other with `superset_with`.

Set rules:

- `reps` must be a positive integer.
- `weight_kg` is optional but recommended.
- `weight_kg` can be fractional.
- `rir` must be `0-5` when present.
- Drop sets should omit `weight_kg` and use `weight_percent_drop`.

## Cycling Plan Generation

Use the cycling schema:

```text
GET /schema?type=cycling
```

Cycling structure:

```text
templates[] -> segments[]
```

Segment kinds:

- `warmup`
- `work`
- `recovery`
- `cooldown`
- `steady`
- `interval_block`

Leaf segments require:

- `kind`
- `name`
- `duration_seconds`
- `target`

`interval_block` requires:

- `kind: "interval_block"`
- `name`
- `repeats`
- `children`

Do not nest `interval_block` inside another `interval_block`.

Target types:

- `hr_bpm_range`: absolute BPM `min` and `max`.
- `rpe`: perceived exertion `min` and `max`.
- `free`: no intensity target.

Use `zone_label` only as display text.

## Upload Flow

1. Determine `plan_type`.
2. Fetch the matching schema from `/schema?type=<plan_type>`.
3. If `strength`, fetch `/exercises/catalog?plan_type=strength` and `/muscle-groups`.
4. If `strength`, optionally fetch `/exercises/{catalog_id}/docs?locale=ru` for matched exercises when coaching notes are needed.
5. Fetch existing versions with `/plans?type=<plan_type>`.
6. Generate JSON with correct `plan_id` and `plan_version`.
7. Validate JSON against the selected schema.
8. Upload with `PUT /plan`.
9. If response contains `_warnings`, show them to the user.
10. If response returns `422`, fix the JSON structure.
11. If response returns `409`, increment `plan_version` above the latest version and retry.

## Output Requirement

When asked to produce a plan JSON, return only valid JSON:

- no Markdown fences
- no comments
- no prose around the JSON
- no unknown top-level fields
