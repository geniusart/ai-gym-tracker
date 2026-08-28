"""Endpoints over the exercise catalog.

The catalog is the single source of truth for "which exercises exist" --
plans reference it via the optional `catalog_id` field, and analytics
groups workout logs across plan versions by it.

Reads are public. Writes (POST/PUT/PATCH) are JWT-authed; today every
authenticated user can edit the global catalog. When we onboard a second
user we'll gate writes behind `require_admin` (see `app/auth.py`), the way
the agent-instruction endpoint already is.

The seed in `tools/seed_data/` is upserted on every container start. Rows
written through these endpoints are stamped `source: "user"` and the seed
skips them entirely, so edits survive restarts; for seed-owned rows the
bootstrap still preserves `deprecated` / `replaced_by` / `created_at`.

Pure validation/normalization helpers live in `_catalog_validators.py`
so they can be unit-tested without pulling in the full app stack.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from app.auth import get_current_user
from app.database import get_db
from app.routes._request_body import (
    read_json_object,
    read_optional_json_object,
)
from app.routes._catalog_validators import (
    SLUG_RE,
    normalize_exercise,
    normalize_muscle,
    validate_exercise_payload_shape,
    validate_muscle_payload,
)

router = APIRouter(tags=["catalog"])


# MARK: - Exercises (read) --------------------------------------------------

@router.get("/exercises/catalog")
async def list_exercises(
    plan_type: str | None = Query(default=None, description=(
        "Filter by plan_type. Today only `strength` returns entries; "
        "`cycling` returns an empty array. Omit to return all."
    )),
    include_deprecated: bool = Query(default=False, description=(
        "If true, includes entries marked `deprecated: true`."
    )),
):
    """Public catalog list. Muscle slugs are resolved to embedded objects."""
    query: dict = {}
    if plan_type:
        query["applies_to"] = plan_type
    if not include_deprecated:
        query["deprecated"] = {"$ne": True}

    cursor = get_db().exercises.find(query, projection={"_id": 0})
    exercises = [doc async for doc in cursor]

    muscles_by_slug = await _muscles_by_slug()
    for ex in exercises:
        _attach_resolved_muscles(ex, muscles_by_slug)
    return exercises


@router.get("/exercises/{slug}")
async def get_exercise(slug: str):
    doc = await get_db().exercises.find_one({"slug": slug}, projection={"_id": 0})
    if not doc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise '{slug}' not found",
        )
    muscles_by_slug = await _muscles_by_slug()
    _attach_resolved_muscles(doc, muscles_by_slug)
    return doc


# MARK: - Exercises (write) -------------------------------------------------

@router.post("/exercises/catalog", status_code=status.HTTP_201_CREATED)
async def create_exercise(
    request: Request,
    user: dict = Depends(get_current_user),
):
    payload = await read_json_object(request, "Exercise body")
    validate_exercise_payload_shape(payload)
    await _verify_muscle_slugs_exist(payload)

    slug = payload["slug"]
    if await get_db().exercises.find_one({"slug": slug}, projection={"_id": 1}):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Exercise '{slug}' already exists",
        )

    now = datetime.now(timezone.utc)
    doc = {
        **normalize_exercise(payload),
        "deprecated": False,
        "replaced_by": None,
        "created_at": now,
        "updated_at": now,
        # Marks the row as user-owned: the startup seed skips these
        # instead of replacing them with tools/seed_data content.
        "source": "user",
    }
    await get_db().exercises.insert_one(doc)
    doc.pop("_id", None)
    return doc


@router.put("/exercises/{slug}")
async def update_exercise(
    slug: str,
    request: Request,
    user: dict = Depends(get_current_user),
):
    """Replace mutable fields. Slug cannot be changed -- to rename, deprecate
    the old slug and create a new one (PATCH /exercises/{slug}/deprecate)."""
    existing = await get_db().exercises.find_one({"slug": slug})
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise '{slug}' not found",
        )

    payload = await read_json_object(request, "Exercise body")
    payload["slug"] = slug  # disallow rename via PUT
    validate_exercise_payload_shape(payload)
    await _verify_muscle_slugs_exist(payload)

    update = normalize_exercise(payload)
    update["updated_at"] = datetime.now(timezone.utc)
    update["source"] = "user"  # keep the startup seed from reverting this
    await get_db().exercises.update_one({"slug": slug}, {"$set": update})

    fresh = await get_db().exercises.find_one({"slug": slug}, projection={"_id": 0})
    return fresh


@router.patch("/exercises/{slug}/deprecate")
async def deprecate_exercise(
    slug: str,
    request: Request,
    user: dict = Depends(get_current_user),
):
    """Mark an exercise deprecated. Optional body: `{ "replaced_by": "<slug>" }`."""
    existing = await get_db().exercises.find_one({"slug": slug})
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise '{slug}' not found",
        )

    body = await read_optional_json_object(request)

    replaced_by = body.get("replaced_by")
    if replaced_by is not None:
        if not isinstance(replaced_by, str) or not SLUG_RE.match(replaced_by):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="replaced_by must be a slug or null",
            )
        if not await get_db().exercises.find_one({"slug": replaced_by}, projection={"_id": 1}):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"replaced_by '{replaced_by}' not in catalog",
            )

    await get_db().exercises.update_one(
        {"slug": slug},
        {"$set": {
            "deprecated": True,
            "replaced_by": replaced_by,
            "updated_at": datetime.now(timezone.utc),
        }},
    )
    return {"slug": slug, "deprecated": True, "replaced_by": replaced_by}


# MARK: - Muscle groups (read) ----------------------------------------------

@router.get("/muscle-groups")
async def list_muscle_groups(
    region: str | None = Query(default=None, description=(
        "Filter by region (legs/chest/back/shoulders/arms/core)."
    )),
):
    query: dict = {}
    if region:
        query["region"] = region
    cursor = get_db().muscle_groups.find(query, projection={"_id": 0})
    return [doc async for doc in cursor]


@router.get("/muscle-groups/{slug}")
async def get_muscle_group(slug: str):
    doc = await get_db().muscle_groups.find_one({"slug": slug}, projection={"_id": 0})
    if not doc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Muscle group '{slug}' not found",
        )
    return doc


# MARK: - Muscle groups (write) ---------------------------------------------

@router.post("/muscle-groups", status_code=status.HTTP_201_CREATED)
async def create_muscle_group(
    request: Request,
    user: dict = Depends(get_current_user),
):
    payload = await read_json_object(request, "Muscle group body")
    validate_muscle_payload(payload)

    slug = payload["slug"]
    if await get_db().muscle_groups.find_one({"slug": slug}, projection={"_id": 1}):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Muscle group '{slug}' already exists",
        )

    now = datetime.now(timezone.utc)
    doc = {
        **normalize_muscle(payload),
        "created_at": now,
        "updated_at": now,
        "source": "user",
    }
    await get_db().muscle_groups.insert_one(doc)
    doc.pop("_id", None)
    return doc


@router.put("/muscle-groups/{slug}")
async def update_muscle_group(
    slug: str,
    request: Request,
    user: dict = Depends(get_current_user),
):
    existing = await get_db().muscle_groups.find_one({"slug": slug})
    if not existing:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Muscle group '{slug}' not found",
        )
    payload = await read_json_object(request, "Muscle group body")
    payload["slug"] = slug
    validate_muscle_payload(payload)

    update = normalize_muscle(payload)
    update["updated_at"] = datetime.now(timezone.utc)
    update["source"] = "user"  # keep the startup seed from reverting this
    await get_db().muscle_groups.update_one({"slug": slug}, {"$set": update})

    return await get_db().muscle_groups.find_one({"slug": slug}, projection={"_id": 0})


# MARK: - Internal ----------------------------------------------------------

async def _verify_muscle_slugs_exist(payload: dict) -> None:
    """Verify every primary/secondary muscle slug references an existing doc."""
    referenced = list(set(
        payload.get("primary_muscles", []) + payload.get("secondary_muscles", [])
    ))
    if not referenced:
        return
    existing = {
        doc["slug"]
        async for doc in get_db().muscle_groups.find(
            {"slug": {"$in": referenced}}, projection={"slug": 1}
        )
    }
    missing = [s for s in referenced if s not in existing]
    if missing:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unknown muscle slugs: {missing}",
        )


async def _muscles_by_slug() -> dict[str, dict]:
    cursor = get_db().muscle_groups.find({}, projection={"_id": 0})
    return {doc["slug"]: doc async for doc in cursor}


def _attach_resolved_muscles(ex: dict, muscles_by_slug: dict[str, dict]) -> None:
    ex["primary_muscles_resolved"] = [
        muscles_by_slug[s] for s in ex.get("primary_muscles", [])
        if s in muscles_by_slug
    ]
    ex["secondary_muscles_resolved"] = [
        muscles_by_slug[s] for s in ex.get("secondary_muscles", [])
        if s in muscles_by_slug
    ]
