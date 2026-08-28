from datetime import datetime

from fastapi import (
    APIRouter, Depends, HTTPException, Query, Request, Response, status,
)

from app.auth import attach_refreshed_token, get_current_user
from app.database import get_db
from app.routes._analytics_helpers import utc_isoformat
from app.routes._request_body import read_json_object
from app.schemas import PlanType

router = APIRouter(tags=["log"])


@router.post("/log")
async def post_log(
    request: Request,
    response: Response,
    user: dict = Depends(get_current_user),
):
    attach_refreshed_token(user, response)

    data = await read_json_object(request, "Log body")
    workouts = data.get("workouts")
    if not isinstance(workouts, list) or len(workouts) == 0:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="workouts must be a non-empty array",
        )

    device_id = request.headers.get("X-Device-Id")
    user_agent = request.headers.get("User-Agent")

    for w in workouts:
        if not isinstance(w, dict) or not w.get("id"):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Each workout must be an object with an 'id' field",
            )

    # One catalog read for the whole batch. A week of offline sync is ~10
    # workouts x 6-8 exercises, and the slugs repeat heavily between them.
    catalog_body_parts = await _catalog_body_parts(workouts)

    upserted = 0
    for w in workouts:
        workout_id = w["id"]

        # Denorm body_part on each strength exercise log entry so analytics
        # queries can group by body_part with a single index hit (no $lookup
        # to plans collection). Cycling logs have segments instead -- skip.
        if w.get("plan_type") == "strength":
            await _enrich_strength_exercises_with_body_part(
                user_id=user["_id"],
                workout=w,
                catalog_body_parts=catalog_body_parts,
            )

        doc = {**w, "user_id": user["_id"]}
        if device_id:
            doc["device_id"] = device_id
        if user_agent:
            doc["user_agent"] = user_agent

        await get_db().workout_logs.update_one(
            {"user_id": user["_id"], "id": workout_id},
            {"$set": doc},
            upsert=True,
        )
        upserted += 1

    return {"upserted": upserted}


@router.get("/log")
async def get_log(
    response: Response,
    since: str | None = None,
    template_id: str | None = None,
    type: PlanType | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    user: dict = Depends(get_current_user),
):
    attach_refreshed_token(user, response)

    query: dict = {"user_id": user["_id"]}

    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="since must be ISO8601 format",
            )
        # `started_at` is stored as a string, so this range filter compares
        # lexicographically: the bound has to be normalized to UTC, or a
        # "+03:00" input silently excludes the "...Z" logs it should match.
        query["started_at"] = {"$gte": utc_isoformat(since_dt)}

    if template_id:
        query["template_id"] = template_id

    if type:
        query["plan_type"] = type.value

    cursor = get_db().workout_logs.find(
        query,
        sort=[("started_at", -1)],
    ).limit(limit)

    results = []
    async for doc in cursor:
        doc.pop("_id", None)
        doc.pop("user_id", None)
        results.append(doc)
    return results


@router.delete("/log/{workout_id}")
async def delete_log(
    workout_id: str,
    response: Response,
    user: dict = Depends(get_current_user),
):
    attach_refreshed_token(user, response)

    result = await get_db().workout_logs.delete_one(
        {"user_id": user["_id"], "id": workout_id},
    )
    if result.deleted_count == 0:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workout not found",
        )
    return {"deleted": workout_id}


# MARK: - Body-part denorm middleware

async def _catalog_body_parts(workouts: list) -> dict[str, str]:
    """Resolve every `catalog_id` referenced by the batch in one query.

    Looking each slug up individually turns a multi-workout sync into
    dozens of sequential round-trips for a catalog of ~30 rows whose slugs
    repeat across workouts.
    """
    slugs = {
        ex["catalog_id"]
        for w in workouts
        if w.get("plan_type") == "strength"
        for ex in (w.get("exercises") or [])
        if isinstance(ex, dict) and ex.get("catalog_id")
    }
    if not slugs:
        return {}
    cursor = get_db().exercises.find(
        {"slug": {"$in": list(slugs)}},
        projection={"slug": 1, "body_part": 1, "_id": 0},
    )
    return {
        doc["slug"]: doc["body_part"]
        async for doc in cursor
        if doc.get("body_part")
    }


async def _enrich_strength_exercises_with_body_part(
    user_id: str,
    workout: dict,
    catalog_body_parts: dict[str, str],
) -> None:
    """Mutates each entry in `workout["exercises"]` adding `body_part`.

    Resolution priority:
      1. `exercise.catalog_id` -> exercises.body_part in catalog
      2. fallback to plans collection lookup by (plan_id, plan_version, exercise_id)
      3. otherwise leave body_part absent
    """
    exercises = workout.get("exercises")
    if not isinstance(exercises, list) or not exercises:
        return

    db = get_db()
    plan_id = workout.get("plan_id")
    plan_version = workout.get("plan_version")

    # Pre-load plan exercises map once if any catalog lookup falls back.
    plan_exercises_by_id: dict[str, str] = {}
    plan_doc_loaded = False

    async def _load_plan_exercises_once() -> None:
        nonlocal plan_doc_loaded
        if plan_doc_loaded:
            return
        plan_doc_loaded = True
        if not (plan_id and plan_version is not None):
            return
        plan_doc = await db.plans.find_one(
            {
                "user_id": user_id,
                "plan_id": plan_id,
                "plan_version": plan_version,
            },
            projection={"templates": 1},
        )
        if not plan_doc:
            return
        for tmpl in plan_doc.get("templates", []) or []:
            for grp in tmpl.get("groups", []) or []:
                for ex in grp.get("exercises", []) or []:
                    ex_id = ex.get("id")
                    bp = ex.get("body_part")
                    if ex_id and bp:
                        plan_exercises_by_id[ex_id] = bp

    for ex_log in exercises:
        if not isinstance(ex_log, dict):
            continue
        if ex_log.get("body_part"):
            # Already populated by client -- respect it.
            continue

        cid = ex_log.get("catalog_id")
        body_part = catalog_body_parts.get(cid) if cid else None

        if not body_part:
            await _load_plan_exercises_once()
            ex_id = ex_log.get("exercise_id")
            if ex_id:
                body_part = plan_exercises_by_id.get(ex_id)

        if body_part:
            ex_log["body_part"] = body_part

