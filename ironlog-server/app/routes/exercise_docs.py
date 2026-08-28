"""Exercise documentation endpoints.

The exercise catalog answers "what exercise is this?". This route answers
"how should it be executed, documented, and sourced?" as a separate reference
collection keyed by exercise slug + locale.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from app.auth import get_current_user
from app.database import get_db
from app.routes._request_body import read_json_object
from app.routes._exercise_doc_validators import (
    VALID_DOC_STATUSES,
    normalize_exercise_doc,
    validate_exercise_doc_payload_shape,
    validate_locale,
)

router = APIRouter(tags=["exercise-docs"])


@router.get("/exercise-docs")
async def list_exercise_docs(
    locale: str = Query(default="ru", description="Documentation locale."),
    status_filter: str | None = Query(
        default=None,
        alias="status",
        description="Optional status filter: draft/reviewed/deprecated.",
    ),
    plan_type: str | None = Query(
        default="strength",
        description="Optional catalog plan_type filter. Use empty/null to skip.",
    ),
):
    validate_locale(locale)
    _validate_optional_status(status_filter)

    query: dict = {"locale": locale}
    if status_filter:
        query["status"] = status_filter

    cursor = get_db().exercise_docs.find(query, projection={"_id": 0})
    docs = [doc async for doc in cursor]
    if not plan_type:
        return docs

    allowed_slugs = await _catalog_slugs(plan_type=plan_type)
    return [doc for doc in docs if doc.get("exercise_slug") in allowed_slugs]


@router.get("/exercise-docs/missing")
async def list_missing_exercise_docs(
    locale: str = Query(default="ru", description="Documentation locale."),
    status_filter: str | None = Query(
        default=None,
        alias="status",
        description="Optional status filter. Use `reviewed` for app-ready gaps.",
    ),
    plan_type: str = Query(default="strength", description="Catalog plan_type filter."),
):
    validate_locale(locale)
    _validate_optional_status(status_filter)

    catalog = await _catalog_docs(plan_type=plan_type)
    query: dict = {"locale": locale}
    if status_filter:
        query["status"] = status_filter

    existing = {
        doc["exercise_slug"]
        async for doc in get_db().exercise_docs.find(
            query,
            projection={"exercise_slug": 1, "_id": 0},
        )
    }
    return [
        {
            "slug": doc["slug"],
            "name": doc["name"],
            "body_part": doc.get("body_part"),
            "equipment": doc.get("equipment"),
        }
        for doc in catalog
        if doc["slug"] not in existing
    ]


@router.get("/exercises/{slug}/docs")
async def get_exercise_doc(
    slug: str,
    locale: str = Query(default="ru", description="Documentation locale."),
):
    validate_locale(locale)
    await _ensure_exercise_exists(slug)

    doc = await get_db().exercise_docs.find_one(
        {"exercise_slug": slug, "locale": locale},
        projection={"_id": 0},
    )
    if not doc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise docs for '{slug}' ({locale}) not found",
        )
    return doc


@router.put("/exercises/{slug}/docs")
async def upsert_exercise_doc(
    slug: str,
    request: Request,
    locale: str = Query(default="ru", description="Documentation locale."),
    user: dict = Depends(get_current_user),
):
    validate_locale(locale)
    await _ensure_exercise_exists(slug)

    payload = await read_json_object(request, "Exercise document body")
    validate_exercise_doc_payload_shape(payload)
    await _verify_alternative_slugs_exist(payload.get("alternative_slugs", []))
    replaced_by = payload.get("replaced_by")
    if replaced_by:
        await _ensure_exercise_exists(replaced_by)

    existing = await get_db().exercise_docs.find_one(
        {"exercise_slug": slug, "locale": locale},
        projection={"content_version": 1, "created_at": 1},
    )
    now = datetime.now(timezone.utc)
    content_version = int((existing or {}).get("content_version", 0)) + 1

    doc = {
        **normalize_exercise_doc(payload),
        "exercise_slug": slug,
        "locale": locale,
        "content_version": content_version,
        "created_at": (existing or {}).get("created_at", now),
        "updated_at": now,
        "updated_by": str(user.get("_id", "")),
    }
    if doc["status"] == "reviewed":
        doc["reviewed_at"] = now
        doc["reviewed_by"] = str(user.get("_id", ""))

    await get_db().exercise_docs.update_one(
        {"exercise_slug": slug, "locale": locale},
        {"$set": doc},
        upsert=True,
    )
    doc.pop("_id", None)
    return doc


async def _ensure_exercise_exists(slug: str) -> None:
    if not await get_db().exercises.find_one({"slug": slug}, projection={"_id": 1}):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Exercise '{slug}' not found",
        )


async def _catalog_docs(plan_type: str) -> list[dict]:
    cursor = get_db().exercises.find(
        {"applies_to": plan_type, "deprecated": {"$ne": True}},
        projection={"_id": 0},
    )
    return [doc async for doc in cursor]


async def _catalog_slugs(plan_type: str) -> set[str]:
    return {doc["slug"] for doc in await _catalog_docs(plan_type)}


async def _verify_alternative_slugs_exist(slugs: list[str]) -> None:
    if not slugs:
        return
    existing = {
        doc["slug"]
        async for doc in get_db().exercises.find(
            {"slug": {"$in": slugs}},
            projection={"slug": 1, "_id": 0},
        )
    }
    missing = [slug for slug in slugs if slug not in existing]
    if missing:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unknown alternative exercise slugs: {missing}",
        )


def _validate_optional_status(value: str | None) -> None:
    if value is not None and value not in VALID_DOC_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"status must be one of {sorted(VALID_DOC_STATUSES)}",
        )
