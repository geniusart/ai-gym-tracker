"""Pure-Python helpers for strength analytics.

Lives in its own module (no project-internal imports) so unit tests can
exercise the math without spinning up `app.config` / mongo / auth.
"""

from datetime import date, datetime, timedelta, timezone
from typing import Iterable


# MARK: - Value coercion

def is_number(v) -> bool:
    """True for real int/float values. `bool` is excluded on purpose: it is
    a subclass of `int`, so `{"reps": true}` would otherwise count as 1 rep."""
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def as_number(v) -> float | None:
    """Coerce a stored set field to float, or None when it is not numeric.

    Logs arrive as raw client JSON (POST /log does not type-check set
    fields), so a string or null can be present for weight/reps. Callers
    must skip those rows rather than compare them against numbers.
    """
    return float(v) if is_number(v) else None


# MARK: - Per-set / per-workout math

def epley_1rm(weight: float, reps: int) -> float:
    """Estimated 1-rep max via Epley: weight * (1 + reps / 30).

    Smooths comparison across rep ranges. 60 kg x 15 reps and 100 kg x 6
    reps both produce ~115 kg estimated 1RM, so a 12-week progression
    that jumps between rep schemes still shows as a clean line.
    """
    return weight * (1.0 + reps / 30.0)


def best_set_of(sets: Iterable[dict]) -> dict | None:
    """Returns the "headline" set for a workout: the heaviest by weight,
    ties broken by reps. None if there are no usable sets."""
    sets = list(sets)
    if not sets:
        return None
    return max(
        sets,
        key=lambda s: (s.get("weight_kg") or 0, s.get("reps") or 0),
    )


def workout_metrics(working_sets: Iterable[dict]) -> dict:
    """Roll up a list of `{weight_kg, reps}` (working sets only) into the
    per-workout headline numbers we expose to clients.

    - `volume`        = sum(weight * reps)
    - `est_1rm`       = max Epley across sets (None if no usable data)
    - `best_set`      = heaviest set
    - `working_sets`  = count of usable sets
    """
    valid = [
        s for s in working_sets
        if is_number(s.get("weight_kg"))
        and is_number(s.get("reps"))
        and s["weight_kg"] >= 0
        and s["reps"] > 0
    ]
    if not valid:
        return {
            "volume": 0.0,
            "est_1rm": None,
            "best_set": None,
            "working_sets": 0,
        }
    return {
        "volume": float(sum(s["weight_kg"] * s["reps"] for s in valid)),
        "est_1rm": max(epley_1rm(s["weight_kg"], s["reps"]) for s in valid),
        "best_set": {
            "weight_kg": best_set_of(valid)["weight_kg"],
            "reps": best_set_of(valid)["reps"],
        },
        "working_sets": len(valid),
    }


# MARK: - Relative deltas (the "headline numbers")

def relative_delta_pct(recent: float, prior: float | None) -> float | None:
    """`(recent - prior) / prior * 100`, rounded to 2 decimals.

    Returns None when `prior` is None or zero -- the front-end should
    render that as "no comparison data" rather than a misleading number.
    """
    if prior is None or prior == 0:
        return None
    return round((recent - prior) / prior * 100.0, 2)


def _window_buckets(
    points: Iterable[dict],
    *,
    days: int,
    now: datetime,
) -> tuple[list[float], list[float]]:
    """Bucket `{date, value}` points into the recent and prior windows.

    Recent window: (now - days, now]
    Prior window:  (now - 2*days, now - days]

    Points with an unparseable date or a non-numeric value are skipped
    rather than compared -- log documents are raw client JSON.
    """
    cutoff_recent = now - timedelta(days=days)
    cutoff_prior = now - timedelta(days=2 * days)
    recent: list[float] = []
    prior: list[float] = []

    for p in points:
        d = to_utc(p.get("date"))
        if d is None:
            continue
        v = p.get("value", 0)
        if not is_number(v):
            continue
        if d > cutoff_recent:
            recent.append(float(v))
        elif d > cutoff_prior:
            prior.append(float(v))

    return recent, prior


def split_window(
    points: Iterable[dict],
    *,
    days: int,
    now: datetime,
) -> tuple[float, float | None]:
    """Sum of `value` in the recent and prior windows of length `days`.

    `prior` is None if no points fall in that window (analytics shouldn't
    fabricate a baseline of zero).
    """
    recent, prior = _window_buckets(points, days=days, now=now)
    return float(sum(recent)), (float(sum(prior)) if prior else None)


def split_window_avg(
    points: Iterable[dict],
    *,
    days: int,
    now: datetime,
) -> tuple[float | None, float | None]:
    """Mean of `value` in each window, None when a window has no points.

    Used for est_1rm, where averaging is the meaningful comparison: a
    month with more sessions must not read as "stronger" than a month
    with fewer, which is what summing would produce.
    """
    recent, prior = _window_buckets(points, days=days, now=now)
    return (
        (sum(recent) / len(recent)) if recent else None,
        (sum(prior) / len(prior)) if prior else None,
    )


def window_is_covered(since: datetime, now: datetime, days: int) -> bool:
    """True when the fetch window reaching back to `since` fully covers the
    prior comparison window of `split_window(days=...)`.

    Without this, a 120-day fetch feeding a 90-day comparison populates the
    recent window with 90 days of data and the prior one with only 30,
    reporting +200% growth for a perfectly flat training load.
    """
    return since <= now - timedelta(days=2 * days)


# MARK: - Date helpers

def week_start(d: datetime) -> date:
    """ISO Monday of the week containing `d`. Used for weekly volume bins."""
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    monday = d - timedelta(days=d.weekday())
    return monday.date()


def parse_iso(s: str) -> datetime:
    """Forgiving ISO 8601 parser: accepts trailing Z."""
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def to_utc(value) -> datetime | None:
    """Normalize a stored date (ISO string or datetime) to an aware UTC
    datetime, or None when it is missing / unparseable.

    Every date that reaches the analytics math must go through here.
    Logs are stored as raw client JSON, so `started_at` can be naive
    ("2026-08-01T10:00:00"), carry a non-UTC offset, or be absent
    entirely; comparing any of those against an aware `now` raises
    TypeError and takes the whole endpoint down for that user.
    """
    if isinstance(value, datetime):
        d = value
    elif isinstance(value, str):
        try:
            d = parse_iso(value)
        except ValueError:
            return None
    else:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone(timezone.utc)


def utc_isoformat(value) -> str | None:
    """`to_utc` rendered back as an ISO string, or None when unparseable.

    Mongo stores `started_at` as a string, so range filters compare
    lexicographically -- the value we send must be normalized to UTC or a
    "+03:00" bound silently excludes matching "...Z" documents.

    Microseconds are dropped and the offset is rendered as "+00:00" (not
    "Z") on purpose: "+" sorts below both "." and "Z", so a bound truncated
    to the second can never exclude a document within that same second,
    whichever of the two spellings the client used.
    """
    d = to_utc(value)
    return d.replace(microsecond=0).isoformat() if d else None
