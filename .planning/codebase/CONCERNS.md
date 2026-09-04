# Codebase Concerns

**Analysis Date:** 2026-04-13

## Tech Debt

**Pervasive silent error swallowing with `try?`:**
- Issue: Nearly every `context.save()` call uses `try?`, discarding SwiftData errors silently. If a save fails (schema migration issue, disk full, constraint violation), the user sees no feedback and data is lost.
- Files: `IronLog/IronLog/ViewModels/ActiveWorkoutViewModel.swift` (lines 171, 489, 582, 647, 664, 675, 689, 721), `IronLog/IronLog/Views/History/WorkoutHistoryView.swift` (lines 61, 82), `IronLog/IronLog/Services/PlanSyncHelper.swift` (line 35)
- Impact: Silent data loss during workout logging -- the most critical user flow. A failed save mid-workout means completed sets vanish with no warning.
- Fix approach: Replace `try?` with proper error handling. At minimum, log errors. For workout persistence, surface an alert to the user.

**Massive ActiveWorkoutView.swift (920 lines):**
- Issue: Single file contains the main view plus 9 private subviews (`ReadyPhaseView`, `PerformingPhaseView`, `RestingPhaseView`, `ExerciseHeader`, `SetRoadmap`, `WeightStepper`, `ExerciseListSheet`, `ExerciseRatingView`, `FinishWorkoutSheet`, `ExerciseNoteSheet`). `WeightStepper` (line 501) is defined but never used.
- Files: `IronLog/IronLog/Views/Workout/ActiveWorkoutView.swift`
- Impact: Hard to navigate; changes to one phase risk breaking another. Dead code (`WeightStepper`) adds confusion.
- Fix approach: Extract each phase view into its own file under `Views/Workout/`. Remove `WeightStepper`.

**ActiveWorkoutViewModel.swift (749 lines) handles too many responsibilities:**
- Issue: The ViewModel manages workout state, set progression, flow orchestration, exercise navigation, incremental persistence, HealthKit integration, sync upload, and exercise notes. This is a "god object" pattern.
- Files: `IronLog/IronLog/ViewModels/ActiveWorkoutViewModel.swift`
- Impact: Any change to persistence logic risks breaking workout flow logic. Testing any single responsibility requires instantiating the entire ViewModel.
- Fix approach: Extract persistence into a dedicated `WorkoutPersistenceService`. Extract HealthKit/sync logic into a `WorkoutFinisher` or post-save handler.

**Duplicated `_attach_refreshed_token` helper on the server:**
- Issue: The function `_attach_refreshed_token` is copy-pasted identically in `routes/plan.py` (line 155) and `routes/log.py` (line 117).
- Files: `ironlog-server/app/routes/plan.py`, `ironlog-server/app/routes/log.py`
- Impact: Maintenance burden; if token refresh logic changes, both copies must be updated.
- Fix approach: Move to a shared middleware or dependency that automatically attaches the refreshed token to every authenticated response.

**Duplicated technique color/label mappings in views:**
- Issue: Technique-to-color and technique-to-label mappings are duplicated across `ExerciseHeader` (line 385), `ExerciseListSheet` (lines 691, 701), and `SetRoadmap` (line 473).
- Files: `IronLog/IronLog/Views/Workout/ActiveWorkoutView.swift`
- Impact: Adding a new technique requires updating 3+ places with identical switch statements.
- Fix approach: Create a `TechniqueUI` helper or extend `Technique` enum with `displayName` and `color` properties.

**PlanSyncHelper only syncs one plan type (strength) with no plan_id:**
- Issue: `PlanSyncHelper.sync()` calls `SyncService.fetchPlan()` with no arguments, which defaults to `type: .strength, id: nil`. This fetches only the latest strength plan, ignoring other plan types or multiple plans of the same type.
- Files: `IronLog/IronLog/Services/PlanSyncHelper.swift` (line 29)
- Impact: When multiple plans exist on the server, only the latest strength plan syncs. Other plan types will never auto-sync.
- Fix approach: Use `fetchPlans()` to list all available plans, then sync each one that has a newer version than local.

**Hardcoded file path in test:**
- Issue: `SamplePlanFileTests` uses an absolute path `/Users/goryanin/Projects/ai-gym-tracker/schemas/sample-plan.json` instead of Bundle or relative path resolution.
- Files: `IronLog/IronLogTests/SamplePlanFileTests.swift` (line 7)
- Impact: Test fails on any other machine or CI environment.
- Fix approach: Add `sample-plan.json` to the test bundle and load via `Bundle(for: Self.self)`.

## Security Considerations

**Default JWT secret in production config:**
- Risk: `jwt_secret` defaults to `"change-me-in-production"` in `config.py`. The docker-compose uses `${JWT_SECRET:-change-me-in-production}`, meaning if the env var is not set, the server runs with a publicly known secret. Any attacker can forge valid JWTs.
- Files: `ironlog-server/app/config.py` (line 7), `ironlog-server/docker-compose.yml` (line 11)
- Current mitigation: The `:-change-me-in-production` fallback in docker-compose at least makes the default explicit.
- Recommendations: Fail startup if `JWT_SECRET` equals the default value. Add a startup check in `main.py` or `config.py` that raises an error in non-dev environments.

**No password strength requirements:**
- Risk: The registration endpoint (`/register`) accepts any non-empty password string. A single-character password is valid.
- Files: `ironlog-server/app/routes/auth_routes.py` (line 21)
- Current mitigation: None.
- Recommendations: Add minimum password length (8+ characters) validation in `AuthRequest` model or route handler.

**No rate limiting on auth endpoints:**
- Risk: `/login` and `/register` have no rate limiting. An attacker can brute-force passwords or spam account creation.
- Files: `ironlog-server/app/routes/auth_routes.py`
- Current mitigation: None.
- Recommendations: Add rate limiting middleware (e.g., `slowapi`) on `/login` and `/register`.

**HTTP-only server communication (no TLS):**
- Risk: The default server URL is `https://72.56.99.246.nip.io` -- plaintext HTTP. JWT tokens, passwords, and workout data are transmitted unencrypted.
- Files: `IronLog/IronLog/Services/SyncService.swift` (line 44)
- Current mitigation: ATS exception configured to allow HTTP.
- Recommendations: Set up TLS (HTTPS) on the server. Use a reverse proxy (nginx/caddy) with Let's Encrypt.

**MongoDB exposed on all interfaces with no auth:**
- Risk: The docker-compose maps MongoDB port `27017` to the host with no authentication configured. If the host firewall allows external access, the database is publicly readable/writable.
- Files: `ironlog-server/docker-compose.yml` (line 17)
- Current mitigation: Relies on host firewall.
- Recommendations: Either remove the port mapping (`ports` section for mongo), bind to `127.0.0.1:27017:27017`, or enable MongoDB authentication.

**No input size limits on plan upload:**
- Risk: The `PUT /plan` endpoint reads the entire request body as JSON with no size limit. A malicious user can upload a multi-GB plan document, exhausting server memory.
- Files: `ironlog-server/app/routes/plan.py` (line 109)
- Current mitigation: None.
- Recommendations: Add `Content-Length` limit via middleware or FastAPI's request body size configuration.

## Performance Bottlenecks

**Fetching all workout history on every tab appearance:**
- Problem: `WorkoutHistoryView` uses `@Query` with no pagination. All finished workouts are loaded into memory.
- Files: `IronLog/IronLog/Views/History/WorkoutHistoryView.swift` (lines 5-9)
- Cause: SwiftData `@Query` with `#Predicate<SDWorkout> { $0.finishedAt != nil }` fetches the entire result set.
- Improvement path: Add `fetchLimit` to the query descriptor, or implement pagination (load more on scroll).

**SDPlan.isSupported iterates entire plan tree:**
- Problem: The `isSupported` computed property traverses all templates, groups, exercises, and sets every time it is accessed. This is called in list views during rendering.
- Files: `IronLog/IronLog/Models/Data/SDPlan.swift` (lines 41-56)
- Cause: Deep nested iteration with no caching.
- Improvement path: Cache the result in a stored property, set during import.

## Fragile Areas

**Workout incremental persistence:**
- Files: `IronLog/IronLog/ViewModels/ActiveWorkoutViewModel.swift` (lines 607-678)
- Why fragile: `persistCompletedSet()` and `persistRestDuration()` find exercise logs by `exerciseId` and sets by `setNumber`. If exercise ordering changes mid-workout (e.g., via `jumpToExercise`), the `currentExerciseIndex` used in `persistRestDuration()` may not match the SwiftData state.
- Safe modification: Always test with jump-to-exercise + rest-duration scenarios. The `prevSetIdx = currentSetIndex - 1` logic (line 655) assumes sequential set completion, which breaks with jump navigation.
- Test coverage: No unit tests for `ActiveWorkoutViewModel` at all.

**String-based technique/body_part/equipment matching:**
- Files: `IronLog/IronLog/Models/Data/SDExercise.swift`, `IronLog/IronLog/Views/Workout/ActiveWorkoutView.swift` (multiple switch statements on raw strings like `"drop_set"`, `"myo_mini"`, `"warmup"`)
- Why fragile: SwiftData models store technique/bodyPart as `String`, while JSON models use proper enums (`Technique`, `BodyPart`). The view layer compares raw strings, so a typo in any string literal silently fails matching.
- Safe modification: Use the `Technique` enum's `rawValue` via constants rather than string literals in views.
- Test coverage: No tests verify that view string literals match enum raw values.

**Schema version compatibility:**
- Files: `IronLog/IronLog/Services/SchemaRegistry.swift`, `ironlog-server/app/schemas/base.py`
- Why fragile: The schema field is a timestamp string (`"2026-04-09T22:00:00Z"`). There is no version ordering logic -- it is just a string comparison. A schema update requires manually updating `PlanSchema.id` in the iOS app and the schema file on the server, with no automated check that they match.
- Safe modification: Update both files simultaneously. Test with plans carrying the old schema timestamp to verify backward compatibility.

## Test Coverage Gaps

**No server tests at all:**
- What's not tested: The entire FastAPI server has zero test files. No tests for auth endpoints, plan validation, log upload/query, or JWT token refresh.
- Files: `ironlog-server/` (no `tests/` directory, no `test_*.py` files)
- Risk: Server-side regressions (validation bypass, auth bugs, data corruption) go unnoticed until production.
- Priority: High

**No ActiveWorkoutViewModel tests:**
- What's not tested: The core workout execution logic -- set completion, flow progression, exercise advancement, incremental persistence, rest timer management, myo-rep dynamic set insertion.
- Files: `IronLog/IronLog/ViewModels/ActiveWorkoutViewModel.swift`
- Risk: This is the most complex file in the app (749 lines) with multiple interacting state machines. Regressions in workout flow directly break the primary user experience.
- Priority: High

**iOS tests only cover plan import:**
- What's not tested: SyncService network logic, WorkoutExportService, HealthKitManager, RestTimerService, all TechniqueFlow implementations, all ViewModels, all Views.
- Files: Only 2 test files exist: `IronLog/IronLogTests/PlanImportTests.swift`, `IronLog/IronLogTests/SamplePlanFileTests.swift`
- Risk: Wide surface area with no automated regression detection.
- Priority: Medium

## Dependencies at Risk

**python-jose is unmaintained:**
- Risk: `python-jose` has not been updated since 2022 and has known security advisories. It is the JWT library used for all authentication.
- Impact: Potential JWT parsing vulnerabilities. No fixes for future security issues.
- Files: `ironlog-server/requirements.txt` (line 7)
- Migration plan: Replace with `PyJWT` (actively maintained) or `joserfc`.

**passlib deprecation warnings:**
- Risk: `passlib` has limited maintenance. The `bcrypt` adapter may produce deprecation warnings with newer `bcrypt` versions.
- Impact: Build warnings, potential breakage on `bcrypt` major version bumps.
- Files: `ironlog-server/requirements.txt` (line 8)
- Migration plan: Consider using `bcrypt` directly instead of through `passlib`.

## Missing Critical Features

**No retry/queue for failed sync uploads:**
- Problem: Workout log upload is fire-and-forget. If it fails (network issue, server down), the workout stays as `syncedAt == nil` with no automatic retry mechanism.
- Files: `IronLog/IronLog/ViewModels/ActiveWorkoutViewModel.swift` (lines 712-727)
- Blocks: Reliable data sync. Users must manually swipe-to-sync from history if auto-upload failed.

**No backup/restore for local SwiftData:**
- Problem: All workout history and plans exist only in local SwiftData. If the user deletes the app or gets a new device, local data is lost. Server only stores workout logs, not the complete local state.
- Blocks: Device migration, data safety.

**No conflict resolution for concurrent plan edits:**
- Problem: If a plan is updated on the server while the user has an active workout using the old version, there is no mechanism to handle the version mismatch or preserve workout context.
- Files: `IronLog/IronLog/Services/PlanSyncHelper.swift`
- Blocks: Safe multi-device usage.

---

*Concerns audit: 2026-04-13*
