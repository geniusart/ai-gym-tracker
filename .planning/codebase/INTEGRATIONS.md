# External Integrations

**Analysis Date:** 2026-04-13

## APIs & External Services

**IronLog Sync Server (self-hosted):**
- The iOS app communicates with a self-hosted FastAPI server
- Client: `IronLog/IronLog/Services/SyncService.swift` (custom `URLSession`-based client)
- Base URL: configurable via UserDefaults, default `https://72.56.99.246.nip.io`
- Auth: JWT Bearer token in `Authorization` header
- Token refresh: server sends `X-Refreshed-Token` header when token nears expiry; client stores automatically
- Device tracking: `X-Device-Id` header (iOS `identifierForVendor`)
- Request timeout: 15 seconds

**Endpoints consumed by iOS app:**
| Method | Path | Used in |
|--------|------|---------|
| POST | /register | `SyncService.register()` |
| POST | /login | `SyncService.login()` |
| GET | /plans | `SyncService.fetchPlans()` |
| GET | /plan | `SyncService.fetchPlan()` |
| POST | /log | `SyncService.uploadLog()` |
| DELETE | /log/{id} | `SyncService.deleteWorkout()` |

**Plan sync helper:**
- `IronLog/IronLog/Services/PlanSyncHelper.swift` - Coordinates plan fetching and import

## Data Storage

**MongoDB (Server):**
- Provider: Self-hosted MongoDB 7 via Docker
- Connection: `MONGODB_URL` env var (default: `mongodb://mongo:27017`)
- Database: `MONGODB_DB` env var (default: `ironlog`)
- Driver: Motor 3.7.0 (async) + PyMongo 4.12.1 (indexes)
- Client setup: `ironlog-server/app/database.py`
- Collections:
  - `users` - User accounts (indexed: email unique)
  - `plans` - Workout plans (compound index: user_id + plan_type + plan_id + plan_version)
  - `workout_logs` - Training logs (indexed: user_id + id unique, user_id + started_at, user_id + template_id)

**SwiftData (iOS):**
- Local persistence on device
- Model prefix convention: `SD` (e.g., `SDWorkout`, `SDPlan`, `SDTemplate`)
- Model files: `IronLog/IronLog/Models/Data/SD*.swift`
- No CloudKit or iCloud sync

**Keychain (iOS):**
- Stores JWT token (key: `ironlog_jwt`) and email (key: `ironlog_email`)
- Custom `KeychainHelper` enum in `IronLog/IronLog/Services/SyncService.swift`
- Uses Security framework directly (SecItemAdd/SecItemCopyMatching/SecItemDelete)

**UserDefaults (iOS):**
- Stores server URL (key: `syncServerURL`)

**File Storage:**
- No cloud file storage
- JSON plan import from local files (`IronLog/IronLog/Services/PlanImportService.swift`)

**Caching:**
- None

## Authentication & Identity

**Custom JWT Auth:**
- Implementation: `ironlog-server/app/auth.py`
- Flow: email/password registration or login returns JWT
- Password hashing: bcrypt via passlib
- Token signing: HS256 via python-jose
- Token expiry: 90 days (configurable)
- Sliding refresh: if token expires within 30 days, server sends fresh token in `X-Refreshed-Token` response header
- iOS auto-logout: on 401 response, token is cleared from Keychain
- Dependency injection: `get_current_user` FastAPI dependency validates token and loads user from MongoDB

## Apple Health (HealthKit)

**Integration:** `IronLog/IronLog/Services/HealthKitManager.swift`
- Singleton: `HealthKitManager.shared`
- Writes: `HKWorkout` objects with activity type `.traditionalStrengthTraining`
- Reads: None (write-only integration)
- Metadata attached: workout brand name, template name, plan name, total volume (kg), total sets
- Entitlement: `com.apple.developer.healthkit` in `IronLog/IronLog/IronLog.entitlements`
- Usage description: `NSHealthUpdateUsageDescription` in Info.plist
- Authorization: requests write-only access to workout type

## Live Activities (ActivityKit)

**Integration:** `IronLog/IronLog/Services/RestTimerActivity.swift`
- Attributes: `RestTimerAttributes` with `ContentState` (phase, timer, exercise info)
- Manager: `RestTimerActivityManager` singleton (`@MainActor`)
- Phases: "performing" (set in progress) and "resting" (countdown timer)
- Overtime support: marks when rest exceeds limit
- Widget UI: `IronLog/IronLogWidgets/RestTimerLiveActivity.swift`
- Info.plist: `NSSupportsLiveActivities: true`
- No push-based updates (pushType: nil)

## JSON Schema System

**Schema files:** `schemas/`
- `schemas/workout-plan.schema.json` - Plan structure definition
- `schemas/workout-log.schema.json` - Log structure definition
- `schemas/sample-plan.json` - Example plan

**Schema validation:**
- Server: validates plans against schema on upload (`ironlog-server/app/routes/plan.py`)
- iOS: structural validation via `PlanSchema.id` constant (`IronLog/IronLog/Services/SchemaRegistry.swift`)
- Schema versioning: timestamp-based identifier (e.g., `2026-04-09T22:00:00Z`)
- Server mounts schemas directory as read-only volume: `../schemas:/schemas:ro`

## Monitoring & Observability

**Server Logging:**
- Structured JSON access logs via `AccessLogMiddleware` (`ironlog-server/app/middleware.py`)
- Fields: timestamp, method, path, status, response time (ms), request_id, client IP
- Output: stdout (captured by Docker)
- Request tracing: `RequestIdMiddleware` adds/propagates `X-Request-Id` header

**Error Tracking:**
- None (no Sentry, Datadog, etc.)

**iOS Logging:**
- No structured logging framework
- Errors surfaced via `SyncError` enum in UI

## CI/CD & Deployment

**Server Hosting:**
- VDS (Virtual Dedicated Server) at `72.56.99.246.nip.io`
- Port mapping: host 8844 (external) mapped to container 8000 (internal)
- Deployment: `docker compose up --build -d`
- Auto-restart: `restart: unless-stopped` on both app and mongo containers

**iOS:**
- No CI/CD pipeline detected
- Build: `cd IronLog && xcodegen generate && open IronLog.xcodeproj`

## Environment Configuration

**Required env vars (server):**
- `JWT_SECRET` - Must be changed from default for production

**Optional env vars (server):**
- `MONGODB_URL` (default: `mongodb://mongo:27017`)
- `MONGODB_DB` (default: `ironlog`)
- `JWT_EXPIRE_DAYS` (default: 90)
- `JWT_REFRESH_THRESHOLD_DAYS` (default: 30)

**Secrets location:**
- Server: env vars via Docker Compose environment block
- iOS: JWT in Keychain, server URL in UserDefaults
- Example file: `ironlog-server/.env.example`

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

---

*Integration audit: 2026-04-13*
