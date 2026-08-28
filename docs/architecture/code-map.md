# Code Map

Status: navigation guide for coding agents. Maps concepts to files, tests, and
server endpoints across the iOS app and the sync server. Read this first when a
task touches unfamiliar code.

Authority note: this file is descriptive routing, not a rule source. Durable
rules live in `AGENTS.md`; deeper design lives in `docs/ARCHITECTURE.md` and
`docs/SPEC.md`. When those disagree with this map, they win and this map is stale.

Maintenance: update this file in the same change that adds or removes a Swift
source, a server module, a route, or a SwiftData model.
`ironlog-server/tests/test_code_map_freshness.py` fails when any `IronLog/*.swift`
or `ironlog-server/*.py` path named here disappears, or when a source module is
added without a row here -- that forces stale entries to be pruned rather than
left to rot.

## Repo split

- `IronLog/IronLog/` -- main iOS app (Swift, SwiftUI, SwiftData, MVVM + Services).
- `IronLog/IronLogWidgets/` -- Live Activity / Dynamic Island widget extension.
- `IronLog/IronLogWatch/` -- watchOS app (HR streaming during workouts).
- `IronLog/IronLogTests/` -- XCTest target.
- `ironlog-server/app/` -- FastAPI app (routes, validators, auth, persistence).
- `ironlog-server/tools/` -- operational scripts + catalog seed data.
- `ironlog-server/tests/` -- pytest unit + route suites.
- `schemas/` -- JSON Schema contracts, mounted read-only into Docker as `/schemas`.

## Conventions

- **Two-layer models**: JSON `Codable` structs (`Models/JSON/`, snake_case keys)
  parse import/export; SwiftData `@Model` classes (`Models/Data/`, `SD` prefix)
  persist. Every `SD*` type mirrors a JSON struct.
- **String foreign keys** join workouts to templates/plans (`templateId`,
  `planId`) so re-import does not orphan history.
- **Technique flows** are stateless: a `TechniqueFlow` reads `isCompleted` flags
  and returns the next `TechniqueStep`; the view model owns mutable state.
- **Pure-Python modules** on the server are prefixed `_` (`_analytics_helpers`,
  `_catalog_validators`, `_exercise_doc_validators`, `_request_body`) -- no DB, no app stack, so
  they are unit-testable in isolation.
- **PlanType** enum must stay in sync: server `PlanType` (`app/schemas/__init__.py`)
  and client `PlanType`/`SchemaRegistry` (`Services/SchemaRegistry.swift`).
  Currently: `strength`, `cycling`.

---

# iOS app (Swift)

## App entry and root

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/IronLogApp.swift` | `@main` entry; builds the SwiftData `ModelContainer` (all `SD*` types), installs `CrashReporter`, uploads pending crashes/logs on launch. | - |
| `IronLog/IronLog/ContentView.swift` | Root `TabView` (Plans / Workout / History / Settings); kicks off plan sync on appear. | - |

## Models -- SwiftData (`@Model`, `SD` prefix)

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Models/Data/SDPlan.swift` | Strength plan entity (planId, planName, planVersion, schema, author); cascade-owns templates. | - |
| `IronLog/IronLog/Models/Data/SDTemplate.swift` | Strength workout template inside a plan; owns exercise groups. | - |
| `IronLog/IronLog/Models/Data/SDExerciseGroup.swift` | Muscle/movement group container inside a template. | - |
| `IronLog/IronLog/Models/Data/SDExercise.swift` | Exercise prescription: body part, equipment, technique, rest, tempo, maxMiniSets, catalog_id. | - |
| `IronLog/IronLog/Models/Data/SDPrescribedSet.swift` | One prescribed set slot: type (working/warmup/drop), reps, weight, rir, weightPercentDrop. | - |
| `IronLog/IronLog/Models/Data/SDWorkout.swift` | Logged strength session: startedAt, finishedAt, templateId/planId FKs, duration, notes, syncedAt. | - |
| `IronLog/IronLog/Models/Data/SDExerciseLog.swift` | Logged exercise instance: exerciseId, bodyPart, technique, supersetWith; owns set logs. | - |
| `IronLog/IronLog/Models/Data/SDSetLog.swift` | One performed set: actual weight/reps/rpe/rir/duration, PR/failed flags, sequenceIndex. | - |
| `IronLog/IronLog/Models/Data/SDCyclingPlan.swift` | Cycling plan entity (planId, planName, planVersion, maxHrBpm); cascade-owns templates. | - |
| `IronLog/IronLog/Models/Data/SDCyclingTemplate.swift` | Cycling template: equipment, progression hints (axis/step/advanceWhen); owns top-level segments. | `CyclingExpanderTests` |
| `IronLog/IronLog/Models/Data/SDCyclingSegment.swift` | Self-referential segment: leaf (duration + target) or interval_block (repeats + children, max depth 1). | `CyclingExpanderTests` |
| `IronLog/IronLog/Models/Data/SDCyclingWorkout.swift` | Logged cycling session: totalDuration, hadHrSource, average/maxHr, calories, syncedAt. | - |
| `IronLog/IronLog/Models/Data/SDCyclingSegmentLog.swift` | Per-segment log: stable segmentPath, actual duration, average/maxHr, inZoneSeconds, skipped. | - |

## Models -- JSON (`Codable` import/export)

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Models/JSON/WorkoutPlanJSON.swift` | Strength plan import schema (PlanType, BodyPart, technique, sets); mirrors `SDPlan`. | `ParsedPlanDispatchTests` |
| `IronLog/IronLog/Models/JSON/CyclingPlanJSON.swift` | Cycling plan import schema (segments, interval_block, target); mirrors `SDCyclingPlan`. | `ParsedPlanDispatchTests`, `CyclingExpanderTests` |
| `IronLog/IronLog/Models/JSON/WorkoutLogJSON.swift` | Strength export envelope (version, exportedAt, workouts[]); mirrors `SDWorkout` tree. | - |
| `IronLog/IronLog/Models/JSON/CyclingWorkoutLogJSON.swift` | Cycling export envelope (`CyclingLogEnvelopeJSON`, per-segment HR/duration); mirrors `SDCyclingWorkout` tree. | - |

## Services -- plan import and sync

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Services/PlanImportService.swift` | Peeks `plan_type`, returns `ParsedPlan` (`.strength`/`.cycling`), imports into SwiftData per type. | `ParsedPlanDispatchTests` |
| `IronLog/IronLog/Services/PlanSyncHelper.swift` | Pulls `/plans`, imports newer versions locally; throttles to ~10 min unless `force: true`. | - |
| `IronLog/IronLog/Services/SchemaRegistry.swift` | Client `PlanType` enum + per-type supported schema timestamps (`strengthId`, `cyclingId`). | - |
| `IronLog/IronLog/Services/PlanSelectionKey.swift` | Encodes/decodes selected-plan storage key `"type:planId"` (back-compatible with legacy planId). | - |

## Services -- networking, auth, export

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Services/SyncService.swift` | Server auth (register/login/logout), plan fetch, log + crash upload; JWT in Keychain; URL fallback + retry. | - |
| `IronLog/IronLog/Services/WorkoutSyncService.swift` | Fire-and-forget upload of finished strength/cycling workouts; per-workout retry cooldown; batches on foreground. | - |
| `IronLog/IronLog/Services/WorkoutExportService.swift` | Converts `SDWorkout` -> `WorkoutLogJSON` and `SDCyclingWorkout` -> `CyclingLogEnvelopeJSON`; pretty JSON for share. | - |
| `IronLog/IronLog/Services/CrashReporter.swift` | Installs `NSException` + signal handlers, writes crash JSON to disk, uploads pending on next launch. | `CrashReporterTests` |

## Services -- heart-rate sources and watch session

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Services/WorkoutSessionManager.swift` | `WCSession` central: start/stop watch session, receive `hr_sample` events, fan out to listeners. | - |
| `IronLog/IronLog/Services/HRSource.swift` | `HRSource` protocol + `NoHRSource` + resolver that ranks the live sources below. | - |
| `IronLog/IronLog/Services/WatchHRSource.swift` | Live HR (~1 Hz) streamed from the watch via `WorkoutSessionManager`. | - |
| `IronLog/IronLog/Services/PhoneWorkoutHRSource.swift` | iOS 26+ iPhone-owned `HKWorkoutSession` for cycling; paired watch auto-joins; writes Activity Rings. | - |
| `IronLog/IronLog/Services/HealthKitHRSource.swift` | Passive HR via `HKAnchoredObjectQuery` from any watch app (Apple Fitness, Strava, etc.). | - |
| `IronLog/IronLog/Services/HealthKitManager.swift` | HealthKit auth; saves finished strength workouts to Apple Health with volume/set metadata. | - |

## Services -- timers and Live Activities

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Services/RestTimerService.swift` | `@Observable` rest countdown (secondsRemaining, overtime); haptics + notification + Live Activity. | - |
| `IronLog/IronLog/Services/RestTimerActivity.swift` | ActivityKit manager for the rest-timer Live Activity (performing vs resting states). | - |
| `IronLog/IronLog/Services/CyclingActivity.swift` | ActivityKit manager for cycling; ships full schedule so the widget self-advances; pause/resume/skip. | - |
| `IronLog/IronLog/Services/CyclingNotificationScheduler.swift` | Schedules a local notification at each segment boundary; survives backgrounding; reschedules on pause/skip. | - |

## TechniqueFlows -- strength executor logic

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/TechniqueFlows/TechniqueFlow.swift` | `TechniqueFlow` protocol + `TechniqueStep` (exerciseIndex, setIndex, instruction, weight, rest, isTerminal, lockWeight). | - |
| `IronLog/IronLog/TechniqueFlows/TechniqueFlowFactory.swift` | Picks the flow by `exercise.technique`; supersets collapse to one `SupersetFlow` over both exercises. | - |
| `IronLog/IronLog/TechniqueFlows/StraightFlow.swift` | Sequential sets; rest after each except the first; terminal on the last set. | - |
| `IronLog/IronLog/TechniqueFlows/DropSetFlow.swift` | Working set -> drop (no rest, weight reduced by weightPercentDrop) -> rest; drops lock weight. | - |
| `IronLog/IronLog/TechniqueFlows/RestPauseFlow.swift` | Activation set -> ~20 s pause -> continuation at same weight; stops on low reps. | - |
| `IronLog/IronLog/TechniqueFlows/MyoRepsFlow.swift` | Activation -> 5 s -> dynamic mini-sets (target reps, `maxMiniSets` cap); adds sets on the fly. | `MyoRepsFlowTests` |
| `IronLog/IronLog/TechniqueFlows/SupersetFlow.swift` | Alternates paired A/B exercises set-by-set; no rest between pair, rest after; multiple pairs per group supported. | `MultipleSupersetPairsTests` |

## ViewModels

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/ViewModels/PlansViewModel.swift` | Import state machine: parse clipboard/file/JSON via `PlanImportService`, preview, confirm insert, duplicate/error dialogs. | `ParsedPlanDispatchTests` |
| `IronLog/IronLog/ViewModels/ActiveWorkoutViewModel.swift` | Strength workout state machine: `ExerciseState[]`, `SetPhase` (ready/performing/resting), drives `TechniqueFlow`, rest timer, HR source, saves session. | `MyoRepsFlowTests`, `MultipleSupersetPairsTests` |
| `IronLog/IronLog/ViewModels/CyclingWorkoutViewModel.swift` | Cycling executor; `CyclingExpander` flattens nested interval_blocks into linear steps, `makeSchedule()` computes absolute `endsAt`; ticks, HR, Live Activity, save. | `CyclingExpanderTests` |

## Views

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLog/Views/Plans/PlansListView.swift` | Strength + cycling plan sections; selection persistence, per-plan delete, pull-to-refresh sync, empty-state import. | - |
| `IronLog/IronLog/Views/Plans/ImportView.swift` | Paste JSON / pick file / load sample; drives `PlansViewModel` parse entry points. | - |
| `IronLog/IronLog/Views/Plans/PlanPreviewView.swift` | Parsed-plan preview before confirm; duplicate-plan conflict UI. | - |
| `IronLog/IronLog/Views/Workout/TemplatePicker.swift` | Pick plan + template; routes to strength or cycling executor; auto-resumes an unfinished workout. | - |
| `IronLog/IronLog/Views/Workout/ActiveWorkoutView.swift` | Strength executor UI; dispatches on `SetPhase`; exercise-list modal; notes/effort before finish. | - |
| `IronLog/IronLog/Views/Workout/CyclingWorkoutView.swift` | Cycling executor UI; current segment, target HR zone, time remaining, pause/resume/skip, HR status. | - |
| `IronLog/IronLog/Views/Workout/DebugLogView.swift` | `#DEBUG`-only raw JSON view of the current workout export. | - |
| `IronLog/IronLog/Views/History/WorkoutHistoryView.swift` | Merges strength + cycling sessions into one chronological list; per-workout detail, manual re-sync, delete. | - |
| `IronLog/IronLog/Views/Settings/SettingsView.swift` | Auth (register/login/logout), server URL config, connection test, sync status. | - |
| `IronLog/IronLog/Views/Components/CockpitStyle.swift` | Theme palette + `CockpitPanel` container + `CockpitChip` badge; `SetTypeStyle` / `TechniqueStyle` set-type and technique label+tint maps. | - |
| `IronLog/IronLog/Shared/WorkoutFormatting.swift` | Weight and duration formatting shared by the app, widgets and watch targets. | - |
| `IronLog/IronLog/Views/Components/SlideButton.swift` | Drag-to-confirm button (e.g. slide to start a set). | - |

## watchOS app (`IronLogWatch`)

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLogWatch/IronLogWatchApp.swift` | `@main` watch entry; requests HealthKit auth; owns `WatchWorkoutManager`. | - |
| `IronLog/IronLogWatch/WatchWorkoutManager.swift` | `HKWorkoutSession` (cycling/strength) driven by iPhone commands; streams HR + calories back over `WCSession`. | - |
| `IronLog/IronLogWatch/LiveWorkoutView.swift` | Watch UI: heart rate, elapsed time, active calories. | - |

## Widget extension (`IronLogWidgets`)

| File | Purpose | Tests |
|---|---|---|
| `IronLog/IronLogWidgets/IronLogWidgetsBundle.swift` | `@main` `WidgetBundle` declaring the rest-timer and cycling Live Activities. | - |
| `IronLog/IronLogWidgets/RestTimerLiveActivity.swift` | Rest-timer Live Activity + Dynamic Island (exercise, weight/next-set, countdown, phase icon). | - |
| `IronLog/IronLogWidgets/CyclingLiveActivity.swift` | Cycling Live Activity + Dynamic Island; self-advances on `endsAt` ticks; next-segment preview. | - |

## iOS tests (`IronLogTests`)

| File | Suite | Tests | Covers |
|---|---|---|---|
| `IronLog/IronLogTests/ParsedPlanDispatchTests.swift` | `ParsedPlanDispatchTests` | 7 | `plan_type` peek + strength/cycling/unknown dispatch + catalog_id roundtrip. |
| `IronLog/IronLogTests/CyclingExpanderTests.swift` | `CyclingExpanderTests` | 14 | interval_block expansion, segment paths, total duration. |
| `IronLog/IronLogTests/MyoRepsFlowTests.swift` | `MyoRepsFlowTests` | 5 | myo-reps activation -> mini-set progression, dynamic set creation, weight lock. |
| `IronLog/IronLogTests/MultipleSupersetPairsTests.swift` | `MultipleSupersetPairsTests` | 2 | multiple superset pairs in one group route + export in order. |
| `IronLog/IronLogTests/CrashReporterTests.swift` | `CrashReporterTests` | 2 | idempotent install, safe `uploadPending` no-op on empty folder. |

---

# Sync server (Python, FastAPI + MongoDB)

## App entry and infrastructure

| File | Purpose | Tests |
|---|---|---|
| `ironlog-server/app/main.py` | FastAPI app + lifespan (connect -> `bootstrap_catalog` -> yield -> close); mounts every router; `GET /health`. | `test_routes` |
| `ironlog-server/app/config.py` | pydantic-settings: MongoDB URL, JWT secret, token expiry/refresh thresholds, schemas dir. | - |
| `ironlog-server/app/database.py` | Motor async client, `get_db()`, and `_ensure_indexes()` for every collection. | - |
| `ironlog-server/app/middleware.py` | `RequestIdMiddleware` (X-Request-Id) + `AccessLogMiddleware` (structured access log). | - |
| `ironlog-server/app/auth.py` | JWT create/decode (HS256, sliding 90 d), bcrypt password hashing, `get_current_user`, `X-Refreshed-Token` refresh. | `test_routes` |

## Validators (plan schema)

| File | Purpose | Tests |
|---|---|---|
| `ironlog-server/app/schemas/__init__.py` | `SCHEMA_REGISTRY` {strength, cycling} + server `PlanType` enum. | `test_base_validator` |
| `ironlog-server/app/schemas/base.py` | Shared base contract: plan_type, plan_id, plan_version, plan_name, schema, created_at. | `test_base_validator` |
| `ironlog-server/app/schemas/strength_v1.py` | Strength structural validation (templates -> groups -> exercises -> sets) + `collect_warnings()` soft checks. | `test_strength_validator`, `test_strength_warnings` |
| `ironlog-server/app/schemas/cycling_v1.py` | Cycling structural validation (segment kinds, target, repeats/children, max nesting depth 1, progression). | `test_cycling_validator` |

## Routes (endpoint handlers)

| File | Purpose | Tests |
|---|---|---|
| `ironlog-server/app/routes/auth_routes.py` | `POST /register`, `POST /login` -> JWT. | `test_routes` |
| `ironlog-server/app/routes/schema.py` | `GET /schema` -- per-type schema description (public). | - |
| `ironlog-server/app/routes/plan.py` | `GET /plans` (full latest content, polymorphic), `PUT /plan` (validate + version bump + `_warnings`). | `test_routes` |
| `ironlog-server/app/routes/log.py` | `POST /log` (upsert; body_part denorm middleware), `GET /log` (query), `DELETE /log/{id}`. | `test_routes` |
| `ironlog-server/app/routes/crash.py` | `POST /crash` (store flexible payload), `GET /crashes` (recent per user). | - |
| `ironlog-server/app/routes/catalog.py` | Exercise + muscle-group CRUD (`/exercises/*`, `/muscle-groups/*`) with slug immutability and deprecate. | `test_routes` |
| `ironlog-server/app/routes/analytics.py` | `GET /analytics/strength/{exercise-progress,body-parts,overview}` server-side aggregation. | `test_routes` |
| `ironlog-server/app/routes/exercise_docs.py` | Exercise execution docs by slug + locale (`/exercise-docs`, `/exercise-docs/missing`, `/exercises/{slug}/docs`). | - |
| `ironlog-server/app/routes/agent_instructions.py` | Serves AI plan-import instructions (`/agent-instructions/plan-import[.json]`) from DB or fallback file. | - |
| `ironlog-server/app/routes/_catalog_validators.py` | Pure validators for exercise/muscle payloads (slug regex, body-part/equipment/plan-type enums, normalize). | `test_catalog_validation` |
| `ironlog-server/app/routes/_exercise_doc_validators.py` | Pure validators for exercise-doc payloads (fields, locale, status, media, sources, normalize). | `test_exercise_doc_validation` |
| `ironlog-server/app/routes/_analytics_helpers.py` | Pure math + date/number coercion: `epley_1rm`, `workout_metrics`, `best_set_of`, `relative_delta_pct`, `split_window`, `split_window_avg`, `window_is_covered`, `week_start`, `parse_iso`, `to_utc`, `utc_isoformat`, `as_number`. | `test_analytics_helpers` |
| `ironlog-server/app/routes/_request_body.py` | Shared raw-JSON body parsing for routes without a pydantic model (`read_json_object`, `read_optional_json_object`); one 422 contract for every such endpoint. | `test_routes` |

## Tools and seed data

| File | Purpose | Tests |
|---|---|---|
| `ironlog-server/tools/bootstrap_catalog.py` | Idempotent seed of exercises + muscle_groups + ru docs on startup; upsert by slug, preserves user edits. | `test_catalog_seed` |
| `ironlog-server/tools/backfill_log_body_parts.py` | One-shot backfill of `body_part` on historical strength logs (catalog_id first, plan fallback). | - |
| `ironlog-server/tools/seed_data/exercises.json` | Seed strength exercises (English name + aliases, muscle slugs). | `test_catalog_seed` |
| `ironlog-server/tools/seed_data/muscle_groups.json` | Seed muscle groups (region + antagonists). | `test_catalog_seed` |
| `ironlog-server/tools/seed_data/exercise_docs.ru.json` | Draft ru execution docs for the seeded catalog. | `test_catalog_seed` |

## Server tests

| File | Tests | Covers |
|---|---|---|
| `ironlog-server/tests/test_analytics_helpers.py` | 39 | pure analytics math edge cases + date/number coercion of raw log values. |
| `ironlog-server/tests/test_base_validator.py` | 8 | shared base contract. |
| `ironlog-server/tests/test_strength_validator.py` | 13 | strength structure + enums. |
| `ironlog-server/tests/test_strength_warnings.py` | 7 | soft `catalog_id` warnings. |
| `ironlog-server/tests/test_cycling_validator.py` | 13 | cycling kinds/target/depth/progression. |
| `ironlog-server/tests/test_catalog_validation.py` | 20 | exercise/muscle payload validation + normalization. |
| `ironlog-server/tests/test_exercise_doc_validation.py` | 8 | exercise-doc payload validation. |
| `ironlog-server/tests/test_catalog_seed.py` | 18 | seed insert/upsert/preserve behavior. |
| `ironlog-server/tests/test_routes.py` | 21 | route contracts (auth, plans, log, catalog, analytics) over an in-memory fake DB. |
| `ironlog-server/tests/conftest.py` | - | shared pytest fixtures (fake DB, sample payloads). |

## Endpoint map

Auth column: JWT = requires `Authorization: Bearer`; none = public.

| Method | Path | Auth | Handler | Description |
|---|---|---|---|---|
| GET | `/health` | none | `main.py` | Healthcheck `{"status":"ok"}`. |
| GET | `/schema` | none | `schema.py` | Schema description per plan_type. |
| POST | `/register` | none | `auth_routes.py` | Create account -> JWT. |
| POST | `/login` | none | `auth_routes.py` | Login -> JWT. |
| GET | `/plans` | JWT | `plan.py` | Latest version of each plan_id, full content (polymorphic). |
| PUT | `/plan` | JWT | `plan.py` | Upload new version; response `_warnings[]` on soft issues. |
| POST | `/log` | JWT | `log.py` | Upsert workouts; strength entries denormed with `body_part`. |
| GET | `/log` | JWT | `log.py` | Query logs (since, template_id, type, limit). |
| DELETE | `/log/{id}` | JWT | `log.py` | Delete one workout log. |
| POST | `/crash` | JWT | `crash.py` | Store a crash report. |
| GET | `/crashes` | JWT | `crash.py` | List recent crash reports. |
| GET | `/exercises/catalog` | none | `catalog.py` | List exercises (`?plan_type`, `?include_deprecated`); muscles resolved. |
| GET | `/exercises/{slug}` | none | `catalog.py` | One exercise with resolved muscles. |
| POST | `/exercises/catalog` | JWT | `catalog.py` | Add exercise (validates muscle slugs). |
| PUT | `/exercises/{slug}` | JWT | `catalog.py` | Update mutable fields (slug immutable). |
| PATCH | `/exercises/{slug}/deprecate` | JWT | `catalog.py` | Soft-delete with optional `replaced_by`. |
| GET | `/muscle-groups` | none | `catalog.py` | List muscle groups (`?region`). |
| GET | `/muscle-groups/{slug}` | none | `catalog.py` | One muscle group. |
| POST | `/muscle-groups` | JWT | `catalog.py` | Add a muscle group. |
| PUT | `/muscle-groups/{slug}` | JWT | `catalog.py` | Update a muscle group. |
| GET | `/analytics/strength/exercise-progress` | JWT | `analytics.py` | Per-exercise series + 30/90 d deltas (`?since`, `?plan_id`). |
| GET | `/analytics/strength/body-parts` | JWT | `analytics.py` | Weekly volume per body_part + deltas (`?weeks`, `?plan_id`). |
| GET | `/analytics/strength/overview` | JWT | `analytics.py` | Top progressing + body-part snapshot + total (`?weeks`, `?plan_id`). |
| GET | `/exercise-docs` | none | `exercise_docs.py` | List execution docs (`?locale`, `?status`, `?plan_type`). |
| GET | `/exercise-docs/missing` | none | `exercise_docs.py` | Catalog slugs missing docs for a locale. |
| GET | `/exercises/{slug}/docs` | none | `exercise_docs.py` | Execution doc for slug + locale. |
| PUT | `/exercises/{slug}/docs` | JWT | `exercise_docs.py` | Upsert execution doc (setup, cues, mistakes, safety, media, sources). |
| GET | `/agent-instructions` | none | `agent_instructions.py` | List available agent instruction sets. |
| GET | `/agent-instructions/plan-import` | none | `agent_instructions.py` | Plan-import instructions as markdown. |
| GET | `/agent-instructions/plan-import.json` | none | `agent_instructions.py` | Plan-import instructions as JSON + live references. |
| PUT | `/agent-instructions/plan-import` | JWT + admin | `agent_instructions.py` | Update stored plan-import instructions. Gated by `require_admin` (`ADMIN_EMAILS` setting or `is_admin` on the user doc) because the GET is unauthenticated. |

## MongoDB collections

| Collection | Written by | Key indexes |
|---|---|---|
| `users` | `auth_routes.py` | `email` unique. |
| `plans` | `plan.py` | unique (user_id, plan_type, plan_id, plan_version). |
| `workout_logs` | `log.py` | (user_id, started_at), (user_id, template_id), (user_id, plan_type, started_at), (user_id, exercises.{exercise_id,catalog_id,body_part}). |
| `exercises` | `catalog.py`, `bootstrap_catalog.py` | `slug` unique; body_part, primary_muscles, applies_to, deprecated. |
| `muscle_groups` | `catalog.py`, `bootstrap_catalog.py` | `slug` unique; region. |
| `exercise_docs` | `exercise_docs.py`, `bootstrap_catalog.py` | (exercise_slug, locale) unique; (locale, status). |
| `crash_logs` | `crash.py` | none -- no dedicated index in `_ensure_indexes()`. |
| `agent_instructions` | `agent_instructions.py` | none -- no dedicated index in `_ensure_indexes()`. |

---

# JSON schema contracts (`schemas/`)

| File | Purpose |
|---|---|
| `schemas/strength-plan.import.schema.json` | Strength import contract (`x-schema-id`: `2026-04-30T00:00:00Z`). |
| `schemas/cycling-plan.import.schema.json` | Cycling import contract (`x-schema-id`: `2026-04-27T00:00:00Z`). |
| `schemas/strength-workout-log.export.schema.json` | Strength log export contract. |
| `schemas/cycling-workout-log.export.schema.json` | Cycling log export contract. |
| `schemas/sample-plan.json` | Strength sample plan for import testing. |

---

# Invariants and where they are enforced

| Invariant | Enforced in |
|---|---|
| `PlanType` values match server and client | `ironlog-server/app/schemas/__init__.py` (`PlanType`) and `IronLog/IronLog/Services/SchemaRegistry.swift` (`PlanType`) |
| Import dispatch by `plan_type` peek | `IronLog/IronLog/Services/PlanImportService.swift` (`ParsedPlan`) |
| New `plan_version` must exceed the stored one | `ironlog-server/app/routes/plan.py` (version check before insert) |
| Base contract required on every plan | `ironlog-server/app/schemas/base.py` (`validate_base`) |
| Cycling interval_block nesting depth <= 1 | `ironlog-server/app/schemas/cycling_v1.py` (depth check) |
| `catalog_id` missing/unknown is a warning, not a 422 | `ironlog-server/app/schemas/strength_v1.py` (`collect_warnings`) |
| Strength log entries carry `body_part` at write time | `ironlog-server/app/routes/log.py` (denorm middleware) + `tools/backfill_log_body_parts.py` |
| Catalog slug is immutable (deprecate + create to rename) | `ironlog-server/app/routes/catalog.py` (no slug update path) + `_catalog_validators.py` |
| est_1RM uses Epley; volume = sum(weight x reps) | `ironlog-server/app/routes/_analytics_helpers.py` (`epley_1rm`, `workout_metrics`) |
| Superset covers both paired exercises in one flow | `IronLog/IronLog/TechniqueFlows/SupersetFlow.swift` + `TechniqueFlowFactory.swift` |

---

# Glossary

- **plan_type** -- discriminator selecting the strength or cycling contract, decoder, validator, and executor. Kept in sync server-side and client-side.
- **schema (x-schema-id)** -- timestamp identifier of the schema a plan was authored against; the app checks it against `SchemaRegistry` support.
- **ParsedPlan** -- Swift enum returned by `PlanImportService.parse` after peeking `plan_type`; carries the decoded per-type JSON struct.
- **TechniqueFlow** -- stateless strength executor that returns the next `TechniqueStep` from `isCompleted` flags (straight, drop_set, rest_pause, myo_reps, superset).
- **CyclingExpander** -- flattens a nested cycling template (interval_blocks expanded by repeat count) into a linear list of executable steps.
- **catalog_id** -- immutable exercise slug shared across plans so analytics tracks one progression line; falls back to (plan_id/exercise_id) when absent.
- **body_part denorm** -- resolving and writing `body_part` onto each strength log entry at `POST /log` time so analytics needs no `$lookup`.
- **est_1rm** -- estimated one-rep max via Epley (`weight * (1 + reps/30)`); volume is the headline metric, top weight alone is not.
- **had_hr_source** -- flag on a cycling log recording whether a live HR source (watch/phone/HealthKit) was attached, versus timer-only.
- **_warnings** -- soft-validation array returned by `PUT /plan` for non-blocking issues (e.g. missing `catalog_id`); never a 422.
