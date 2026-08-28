from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase
from pymongo import IndexModel, ASCENDING, DESCENDING

from app.config import settings

client: AsyncIOMotorClient = None  # type: ignore[assignment]
_db: AsyncIOMotorDatabase = None  # type: ignore[assignment]


def get_db() -> AsyncIOMotorDatabase:
    if _db is None:
        raise RuntimeError("Database is not initialized; call connect() before get_db().")
    return _db


async def connect() -> None:
    global client, _db
    client = AsyncIOMotorClient(settings.mongodb_url)
    _db = client[settings.mongodb_db]
    await _ensure_indexes()


async def close() -> None:
    if client:
        client.close()


async def _ensure_indexes() -> None:
    # users
    await _db.users.create_indexes([
        IndexModel([("email", ASCENDING)], unique=True),
    ])

    # plans
    await _db.plans.create_indexes([
        IndexModel(
            [
                ("user_id", ASCENDING),
                ("plan_type", ASCENDING),
                ("plan_id", ASCENDING),
                ("plan_version", ASCENDING),
            ],
            unique=True,
        ),
        IndexModel(
            [
                ("user_id", ASCENDING),
                ("plan_type", ASCENDING),
                ("plan_id", ASCENDING),
                ("plan_version", DESCENDING),
            ],
        ),
    ])

    # workout_logs
    await _db.workout_logs.create_indexes([
        IndexModel(
            [("user_id", ASCENDING), ("id", ASCENDING)],
            unique=True,
        ),
        IndexModel([("user_id", ASCENDING), ("started_at", DESCENDING)]),
        IndexModel([("user_id", ASCENDING), ("template_id", ASCENDING)]),
        # Analytics: per (user, plan_type) timeseries
        IndexModel([
            ("user_id", ASCENDING),
            ("plan_type", ASCENDING),
            ("started_at", DESCENDING),
        ]),
        # Analytics: per-exercise progression (multikey on exercises.exercise_id)
        IndexModel([
            ("user_id", ASCENDING),
            ("exercises.exercise_id", ASCENDING),
            ("started_at", DESCENDING),
        ]),
        # Analytics: per-catalog-id grouping (multikey on exercises.catalog_id)
        IndexModel([
            ("user_id", ASCENDING),
            ("exercises.catalog_id", ASCENDING),
            ("started_at", DESCENDING),
        ]),
        # Analytics: per-body-part group-by (after denorm at log-write time)
        IndexModel([
            ("user_id", ASCENDING),
            ("exercises.body_part", ASCENDING),
            ("started_at", DESCENDING),
        ]),
    ])

    # crash reports: listed per user, newest first
    await _db.crash_logs.create_indexes([
        IndexModel([("user_id", ASCENDING), ("received_at", DESCENDING)]),
    ])

    # exercise catalog
    await _db.muscle_groups.create_indexes([
        IndexModel([("slug", ASCENDING)], unique=True),
        IndexModel([("region", ASCENDING)]),
    ])
    await _db.exercises.create_indexes([
        IndexModel([("slug", ASCENDING)], unique=True),
        IndexModel([("body_part", ASCENDING)]),
        IndexModel([("primary_muscles", ASCENDING)]),
        IndexModel([("applies_to", ASCENDING)]),
        IndexModel([("deprecated", ASCENDING)]),
    ])

    # exercise documentation reference
    await _db.exercise_docs.create_indexes([
        IndexModel([("exercise_slug", ASCENDING), ("locale", ASCENDING)], unique=True),
        IndexModel([("locale", ASCENDING), ("status", ASCENDING)]),
        IndexModel([("exercise_slug", ASCENDING)]),
    ])
