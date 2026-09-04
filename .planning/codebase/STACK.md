# Technology Stack

**Analysis Date:** 2026-04-13

## Languages

**Primary:**
- Swift 5.9 - iOS app (`IronLog/`)
- Python 3.12 - Sync server (`ironlog-server/`)

**Secondary:**
- JSON - Schema definitions (`schemas/`), plan import format

## Runtime

**iOS:**
- iOS 17.0+ deployment target
- Xcode 16.0+
- XcodeGen 2.38+ for project generation

**Server:**
- Python 3.12 (Docker image: `python:3.12-slim`)
- Uvicorn ASGI server

**Package Manager:**
- pip (Python) with `ironlog-server/requirements.txt`
- No SPM dependencies -- all iOS frameworks are first-party Apple SDKs
- Lockfile: Not present (no `requirements.lock` or `Package.resolved`)

## Frameworks

**iOS Core:**
- SwiftUI - UI framework
- SwiftData - Persistence (NOT CoreData)
- HealthKit - Apple Health workout export (`IronLog/IronLog/Services/HealthKitManager.swift`)
- ActivityKit - Live Activities for rest timer (`IronLog/IronLog/Services/RestTimerActivity.swift`)
- WidgetKit - Widget extension for Live Activity UI (`IronLog/IronLogWidgets/`)

**Server Core:**
- FastAPI 0.115.12 - Web framework (`ironlog-server/app/main.py`)
- Motor 3.7.0 - Async MongoDB driver (`ironlog-server/app/database.py`)
- Pydantic 2.11.2 - Data validation and settings (`ironlog-server/app/schemas/`)
- Pydantic-Settings 2.9.1 - Environment-based config (`ironlog-server/app/config.py`)

**Testing:**
- XCTest - iOS unit tests (`IronLog/IronLogTests/`)

**Build/Dev:**
- XcodeGen - Generates `.xcodeproj` from `IronLog/project.yml`
- Docker + Docker Compose - Server containerization (`ironlog-server/Dockerfile`, `ironlog-server/docker-compose.yml`)

## Key Dependencies

**Server -- Critical:**
- `motor` 3.7.0 - Async MongoDB client (primary data store driver)
- `python-jose[cryptography]` 3.4.0 - JWT creation and validation (`ironlog-server/app/auth.py`)
- `passlib[bcrypt]` 1.7.4 + `bcrypt` 4.2.1 - Password hashing (`ironlog-server/app/auth.py`)
- `pymongo` 4.12.1 - MongoDB index management (used alongside Motor)

**Server -- Infrastructure:**
- `uvicorn[standard]` 0.34.2 - ASGI server
- `python-multipart` 0.0.20 - Form data parsing (required by FastAPI auth endpoints)

**iOS -- No third-party dependencies:**
- All functionality uses Apple first-party frameworks
- HTTP networking: `URLSession` (no Alamofire)
- JSON parsing: `Codable` (no third-party)
- Keychain: Security framework directly (`IronLog/IronLog/Services/SyncService.swift`, `KeychainHelper` enum)

## Configuration

**Server Environment:**
- `MONGODB_URL` - MongoDB connection string (default: `mongodb://mongo:27017`)
- `MONGODB_DB` - Database name (default: `ironlog`)
- `JWT_SECRET` - Token signing secret
- `JWT_EXPIRE_DAYS` - Token expiry (default: 90)
- `JWT_REFRESH_THRESHOLD_DAYS` - Auto-refresh window (default: 30)
- Config class: `ironlog-server/app/config.py` (Pydantic `BaseSettings`)
- Example env file: `ironlog-server/.env.example`

**iOS Configuration:**
- Server URL stored in `UserDefaults` (key: `syncServerURL`)
- Default server: `https://72.56.99.246.nip.io`
- JWT token and email stored in iOS Keychain
- App Transport Security: `NSAllowsArbitraryLoads: true` (allows HTTP)
- Bundle ID: `com.W88C7J82R5.ironlog`

**Build:**
- iOS project generated from `IronLog/project.yml` via XcodeGen
- Server built via `ironlog-server/Dockerfile`
- Docker Compose orchestrates app + MongoDB (`ironlog-server/docker-compose.yml`)

## Platform Requirements

**Development:**
- macOS with Xcode 16.0+
- XcodeGen (`brew install xcodegen`)
- Docker and Docker Compose (for server)

**Production -- iOS:**
- iOS 17.0+
- Portrait orientation only
- HealthKit entitlement
- Live Activities capability

**Production -- Server:**
- Docker host with ports 8000 (app) and 27017 (MongoDB)
- Default deployment: `72.56.99.246.nip.io`
- MongoDB 7.x (Docker image: `mongo:7`)
- Persistent volume: `mongo_data` for database storage

## Targets

The iOS project has three targets defined in `IronLog/project.yml`:

| Target | Type | Purpose |
|--------|------|---------|
| `IronLog` | application | Main iOS app |
| `IronLogWidgets` | app-extension | WidgetKit extension for Live Activity UI |
| `IronLogTests` | bundle.unit-test | Unit tests |

---

*Stack analysis: 2026-04-13*
