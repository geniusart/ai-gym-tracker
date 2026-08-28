"""Strength analytics endpoints.

These are server-side aggregations over `workout_logs`. Three endpoints,
each returning JSON ready to drive a chart or a "headline number" card:

  GET /analytics/strength/exercise-progress
        per-exercise series + 30/90-day relative deltas

  GET /analytics/strength/body-parts
        weekly volume per body part + 30/90-day deltas

  GET /analytics/strength/overview
        cross-exercise summary: top progressing, body-part snapshot,
        workout count

Group key for cross-plan continuity is `catalog_id` when the log carries
it, falling back to `(plan_id, exercise_id)` for older entries.

Body-part aggregation relies on the denorm middleware that writes
`exercises[].body_part` into each strength log (`app/routes/log.py`).
Logs predating that middleware are covered by
`tools/backfill_log_body_parts.py`.
"""

from collections import defaultdict
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import attach_refreshed_token, get_current_user
from app.database import get_db
from app.routes._analytics_helpers import (
    as_number,
    parse_iso,
    relative_delta_pct,
    split_window,
    split_window_avg,
    to_utc,
    utc_isoformat,
    week_start,
    window_is_covered,
    workout_metrics,
)

router = APIRouter(tags=["analytics"], prefix="/analytics/strength")


# Default lookback when caller does not pass `since`. Must be at least
# twice the widest comparison window (90 days) so the prior half of that
# comparison is backed by data instead of by the edge of the fetch.
_DEFAULT_LOOKBACK_DAYS = 180

# Set types excluded from volume. Everything else -- drop sets, myo-reps,
# rest-pause continuations, backoff sets -- is real work the plans
# prescribe and the client logs, so it counts toward tonnage.
_EXCLUDED_SET_TYPES = ["warmup"]


# MARK: - Exercise progress -------------------------------------------------

@router.get("/exercise-progress")
async def exercise_progress(
    since: str | None = Query(default=None, description=(
        "ISO 8601 date/datetime. Defaults to now - 180 days."
    )),
    plan_id: str | None = Query(default=None, description=(
        "Optional: restrict to a specific plan_id."
    )),
    user: dict = Depends(get_current_user),
    response: Response = None,
):
    """Per-exercise progression series + 30/90-day deltas.

    Group key: `catalog_id` if present in the log, else `<plan_id>/<exercise_id>`.
    """
    attach_refreshed_token(user, response)
    since_dt, now = _parse_window(since)

    raw = await _fetch_strength_working_sets(
        user_id=user["_id"], since=since_dt, plan_id=plan_id,
    )

    # Group by (group_key, workout_id) -> set list -> workout_metrics
    by_key_workout: dict[tuple, dict] = defaultdict(lambda: {
        "sets": [],
        "date": None,
        "exercise_name": None,
        "catalog_id": None,
        "body_part": None,
    })
    for r in raw:
        key = r["group_key"]
        wid = r["workout_id"]
        bucket = by_key_workout[(key, wid)]
        bucket["sets"].append({"weight_kg": r["weight_kg"], "reps": r["reps"]})
        bucket["date"] = r["date"]
        bucket["exercise_name"] = r["exercise_name"]
        bucket["catalog_id"] = r["catalog_id"]
        bucket["body_part"] = r["body_part"]

    # Roll up per (key, workout) -> per key. `rows` pairs each point with
    # its parsed date so ordering and window math use the real instant,
    # not the ISO string (which sorts "+03:00" after "Z" for the same moment).
    per_key: dict[str, dict] = defaultdict(lambda: {
        "rows": [],
        "exercise_name": None,
        "catalog_id": None,
        "body_part": None,
    })
    for (key, wid), b in by_key_workout.items():
        m = workout_metrics(b["sets"])
        per_key[key]["rows"].append((b["date"], {
            "date": b["date"].isoformat(),
            "workout_id": wid,
            "volume": m["volume"],
            "est_1rm": _round(m["est_1rm"]),
            "best_set": m["best_set"],
            "working_sets": m["working_sets"],
        }))
        # Keep latest non-null metadata
        per_key[key]["exercise_name"] = b["exercise_name"] or per_key[key]["exercise_name"]
        per_key[key]["catalog_id"] = b["catalog_id"] or per_key[key]["catalog_id"]
        per_key[key]["body_part"] = b["body_part"] or per_key[key]["body_part"]

    # Sort points within each key by date asc
    for payload in per_key.values():
        payload["rows"].sort(key=lambda row: row[0])

    # Resolve catalog metadata (display_name + primary_muscles) where possible
    catalog_lookup = await _catalog_lookup_for_keys(per_key.keys())

    out = []
    for key, payload in per_key.items():
        cat = catalog_lookup.get(key)
        key_type = "catalog_id" if cat else "plan_local"
        display_name = (cat or {}).get("name") or payload["exercise_name"] or key
        body_part = (cat or {}).get("body_part") or payload["body_part"]
        primary_muscles = (cat or {}).get("primary_muscles") or []

        rows = payload["rows"]
        points = [p for _, p in rows]

        # Compute deltas (volume + est_1rm) over 30 / 90 day windows.
        # A delta is only reported when the fetch window covers the prior
        # half too -- otherwise a full recent window is compared against a
        # truncated baseline and reads as growth that never happened.
        volume_pts = [{"date": d, "value": p["volume"]} for d, p in rows]
        rec_v_30, prior_v_30 = split_window(volume_pts, days=30, now=now)
        rec_v_90, prior_v_90 = split_window(volume_pts, days=90, now=now)

        e1rm_pts = [
            {"date": d, "value": p["est_1rm"]}
            for d, p in rows if p["est_1rm"] is not None
        ]
        rec_avg_e30, prior_avg_e30 = split_window_avg(e1rm_pts, days=30, now=now)

        out.append({
            "key": key,
            "key_type": key_type,
            "display_name": display_name,
            "body_part": body_part,
            "primary_muscles": primary_muscles,
            "points": points,
            "deltas": {
                "volume_pct_30d": _delta_if_covered(
                    rec_v_30, prior_v_30, since=since_dt, now=now, days=30,
                ),
                "volume_pct_90d": _delta_if_covered(
                    rec_v_90, prior_v_90, since=since_dt, now=now, days=90,
                ),
                "est_1rm_pct_30d": _delta_if_covered(
                    rec_avg_e30, prior_avg_e30, since=since_dt, now=now, days=30,
                ),
            },
        })

    out.sort(key=lambda x: x["display_name"].lower())
    return out


# MARK: - Body parts --------------------------------------------------------

@router.get("/body-parts")
async def body_parts(
    weeks: int = Query(default=12, ge=1, le=52, description=(
        "Lookback window in weeks. Returned weekly_volume contains this many bins."
    )),
    plan_id: str | None = Query(default=None),
    user: dict = Depends(get_current_user),
    response: Response = None,
):
    """Weekly volume per body part + 30/90-day relative deltas."""
    attach_refreshed_token(user, response)
    now = datetime.now(timezone.utc)
    since_dt = now - timedelta(weeks=weeks)

    raw = await _fetch_strength_working_sets(
        user_id=user["_id"], since=since_dt, plan_id=plan_id,
    )

    # Per-workout volume per body_part (sum within each workout to attribute
    # the workout-day's total cleanly to a single weekly bin).
    by_bp_workout: dict[tuple, float] = defaultdict(float)
    by_bp_workout_sets: dict[tuple, int] = defaultdict(int)
    workout_dates: dict[str, datetime] = {}
    bp_exercises: dict[str, set] = defaultdict(set)
    cutoff_30d_for_exercises = now - timedelta(days=30)

    for r in raw:
        bp = r["body_part"]
        if not bp:
            continue
        wid = r["workout_id"]
        d = r["date"]
        workout_dates[wid] = d
        weight = r["weight_kg"]
        reps = r["reps"]
        # Same validity rule as `workout_metrics`: weight may be 0 (body-
        # weight work is real training volume), reps may not. Rejecting
        # weight == 0 here used to drop whole body parts -- a back session
        # of pull-ups simply vanished from this endpoint.
        if weight is None or reps is None or weight < 0 or reps <= 0:
            continue
        by_bp_workout[(bp, wid)] += weight * reps
        by_bp_workout_sets[(bp, wid)] += 1
        if d >= cutoff_30d_for_exercises:
            bp_exercises[bp].add(r["group_key"])

    # Aggregate to weekly bins per body_part (for the chart), and keep the
    # per-workout points (for the deltas). Windows must be measured on the
    # real workout date: a bin labelled with its Monday can sit up to six
    # days away from the workout it holds, which is enough to push a
    # session inside the 30-day window into the prior one.
    weekly: dict[str, dict[str, dict]] = defaultdict(
        lambda: defaultdict(lambda: {"volume": 0.0, "working_sets": 0})
    )
    bp_points: dict[str, list[dict]] = defaultdict(list)
    for (bp, wid), vol in by_bp_workout.items():
        d = workout_dates[wid]
        sets = by_bp_workout_sets[(bp, wid)]
        bp_points[bp].append({"date": d, "value": vol, "sets": sets})
        bin_ = weekly[bp][week_start(d).isoformat()]
        bin_["volume"] += vol
        bin_["working_sets"] += sets

    # Pre-build the full set of week_start labels in the window (so we can
    # render a stable x-axis even if some weeks have no data).
    all_week_starts = []
    cursor = week_start(since_dt)
    end_week = week_start(now)
    while cursor <= end_week:
        all_week_starts.append(cursor.isoformat())
        cursor = cursor + timedelta(days=7)

    out = []
    for bp, bins in weekly.items():
        weekly_volume = [
            {
                "week_start": w,
                "volume": round(bins.get(w, {"volume": 0.0})["volume"], 2),
                "working_sets": bins.get(w, {"working_sets": 0})["working_sets"],
            }
            for w in all_week_starts
        ]

        # Deltas over 30/90 day windows, measured on per-workout points
        pts = bp_points[bp]
        rec_30, prior_30 = split_window(pts, days=30, now=now)
        rec_90, prior_90 = split_window(pts, days=90, now=now)

        # Sets per week over the recent 30 days. The divisor is the window
        # itself (30/7 weeks), not the number of Monday labels inside it --
        # that count flips between 4 and 5 depending on today's weekday and
        # moved this average by 20% overnight with unchanged data.
        cutoff_30 = now - timedelta(days=30)
        sets_in_30d = sum(p["sets"] for p in pts if p["date"] > cutoff_30)

        out.append({
            "body_part": bp,
            "weekly_volume": weekly_volume,
            "volume_30d": round(rec_30, 2),
            "deltas": {
                "volume_pct_30d": _delta_if_covered(
                    rec_30, prior_30, since=since_dt, now=now, days=30,
                ),
                "volume_pct_90d": _delta_if_covered(
                    rec_90, prior_90, since=since_dt, now=now, days=90,
                ),
            },
            "sets_per_week_avg_30d": round(sets_in_30d / (30 / 7), 1),
            "exercises_count_30d": len(bp_exercises.get(bp, set())),
        })

    # Stable sort: heaviest volume first
    out.sort(key=lambda r: -sum(p["volume"] for p in r["weekly_volume"]))
    return out


# MARK: - Overview ----------------------------------------------------------

@router.get("/overview")
async def overview(
    weeks: int = Query(default=12, ge=1, le=52),
    plan_id: str | None = Query(default=None),
    user: dict = Depends(get_current_user),
    response: Response = None,
):
    """Headline summary: top progressing exercises (by volume %), body-part
    snapshot, total workouts in window."""
    attach_refreshed_token(user, response)
    now = datetime.now(timezone.utc)
    since_dt = now - timedelta(weeks=weeks)

    # Reuse the two endpoints' core logic by calling them directly.
    progress = await exercise_progress(  # type: ignore[call-arg]
        since=since_dt.isoformat(), plan_id=plan_id,
        user=user, response=response,
    )
    bp = await body_parts(  # type: ignore[call-arg]
        weeks=weeks, plan_id=plan_id, user=user, response=response,
    )

    # Top 5 by volume_pct_30d
    rated = [
        ex for ex in progress
        if ex["deltas"]["volume_pct_30d"] is not None
    ]
    top_progressing = sorted(
        rated, key=lambda x: -x["deltas"]["volume_pct_30d"],
    )[:5]
    top_progressing = [
        {
            "key": ex["key"],
            "display_name": ex["display_name"],
            "body_part": ex["body_part"],
            "volume_pct_30d": ex["deltas"]["volume_pct_30d"],
        }
        for ex in top_progressing
    ]

    body_part_summary = {
        row["body_part"]: {
            "volume_30d": row["volume_30d"],
            "volume_pct_30d": row["deltas"]["volume_pct_30d"],
            "sets_per_week_avg_30d": row["sets_per_week_avg_30d"],
        }
        for row in bp
    }

    # Count distinct workouts (any plan_type=strength) in the window
    workouts_count = await get_db().workout_logs.count_documents({
        "user_id": user["_id"],
        "plan_type": "strength",
        "started_at": {"$gte": utc_isoformat(since_dt)},
    })

    return {
        "since": since_dt.isoformat(),
        "weeks": weeks,
        "total_strength_workouts": workouts_count,
        "top_progressing_volume_30d": top_progressing,
        "body_part_summary_30d": body_part_summary,
    }


# MARK: - Internal ----------------------------------------------------------

async def _fetch_strength_working_sets(
    *,
    user_id,
    since: datetime,
    plan_id: str | None,
) -> list[dict]:
    """Mongo aggregation: returns a flat list of working-set rows with the
    minimal fields each analytic needs. We do the math in Python, which
    is plenty fast at our scale (single user, few thousand sets) and far
    easier to reason about than nested $group pipelines."""
    match: dict = {
        "user_id": user_id,
        "plan_type": "strength",
        "started_at": {"$gte": utc_isoformat(since)},
    }
    if plan_id:
        match["plan_id"] = plan_id

    pipeline = [
        {"$match": match},
        {"$unwind": "$exercises"},
        {"$unwind": "$exercises.sets"},
        # `$nin` (rather than `$eq: "working"`) also keeps sets whose
        # `set_type` is absent -- the export schema declares "working" as
        # that field's default.
        {"$match": {"exercises.sets.set_type": {"$nin": _EXCLUDED_SET_TYPES}}},
        {"$project": {
            "_id": 0,
            "workout_id": "$id",
            "date": "$started_at",
            "plan_id": "$plan_id",
            "exercise_id": "$exercises.exercise_id",
            "exercise_name": "$exercises.exercise_name",
            "catalog_id": "$exercises.catalog_id",
            "body_part": "$exercises.body_part",
            "weight_kg": "$exercises.sets.weight_kg",
            "reps": "$exercises.sets.reps",
        }},
    ]

    raw = []
    async for doc in get_db().workout_logs.aggregate(pipeline):
        # Defensive normalization: logs are stored as raw client JSON, so
        # older entries (predating Phase A2) may not carry every projected
        # field, and `started_at` / `weight_kg` / `reps` can hold a naive
        # date, a string, or nothing at all. Coerce once here so no
        # downstream comparison can raise on the shape of a single log.
        date = to_utc(doc.get("date"))
        if date is None:
            continue
        # BSON stores integers written as `10.0` by a client as a double;
        # keep whole rep counts as ints so responses stay `"reps": 10`.
        reps = as_number(doc.get("reps"))
        if reps is not None and reps.is_integer():
            reps = int(reps)
        cid = doc.get("catalog_id")
        normalized = {
            "workout_id": doc.get("workout_id"),
            "date": date,
            "plan_id": doc.get("plan_id"),
            "exercise_id": doc.get("exercise_id"),
            "exercise_name": doc.get("exercise_name"),
            "catalog_id": cid,
            "body_part": doc.get("body_part"),
            "weight_kg": as_number(doc.get("weight_kg")),
            "reps": reps,
            "group_key": (
                cid if cid
                else f'{doc.get("plan_id", "?")}/{doc.get("exercise_id", "?")}'
            ),
        }
        raw.append(normalized)
    return raw


async def _catalog_lookup_for_keys(keys) -> dict[str, dict]:
    """For keys that are catalog slugs, fetch the catalog entry to use as
    display_name + body_part + primary_muscles source. Keys of the form
    "plan_id/exercise_id" are skipped (no catalog entry to attach)."""
    slugs = [k for k in keys if "/" not in k]
    if not slugs:
        return {}
    cursor = get_db().exercises.find(
        {"slug": {"$in": list(slugs)}},
        projection={
            "_id": 0, "slug": 1, "name": 1,
            "body_part": 1, "primary_muscles": 1,
        },
    )
    return {doc["slug"]: doc async for doc in cursor}


def _parse_window(since: str | None) -> tuple[datetime, datetime]:
    now = datetime.now(timezone.utc)
    if since:
        try:
            since_dt = parse_iso(since)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="`since` must be ISO 8601 (e.g. 2026-04-01 or with time)",
            )
        # Naive input means UTC; an explicit offset is converted, so the
        # string bound sent to Mongo compares against stored "...Z" values.
        since_dt = to_utc(since_dt)
    else:
        since_dt = now - timedelta(days=_DEFAULT_LOOKBACK_DAYS)
    return since_dt, now


def _round(v):
    return round(v, 2) if isinstance(v, (int, float)) else v


def _delta_if_covered(
    recent: float | None,
    prior: float | None,
    *,
    since: datetime,
    now: datetime,
    days: int,
) -> float | None:
    """`relative_delta_pct`, reported only when the fetch window reaching
    back to `since` covers the prior comparison window in full.

    Returning None makes the client render "no comparison data", which is
    honest; comparing against a partially covered baseline is not.
    """
    if recent is None or prior is None:
        return None
    if not window_is_covered(since, now, days):
        return None
    return relative_delta_pct(recent, prior)

