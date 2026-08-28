"""Pure-Python validation/normalization helpers for catalog payloads.

Lives in its own module (with no project-internal imports) so unit tests
can exercise the logic without spinning up `app.config` / `app.database`
/ `app.auth` -- handy on dev machines where pydantic-settings can't be
installed for reasons beyond the project (e.g. Python 3.14 wheels).
"""

import re

from fastapi import HTTPException, status

# Slug convention: lowercase ASCII letters/digits/underscore only.
# Anchored with \Z, not $: in Python "$" also matches just before a
# trailing newline, so "squat\n" would pass as a slug, dodge the
# duplicate check and add a second, unreachable catalog row.
SLUG_RE = re.compile(r"^[a-z][a-z0-9_]*\Z")

# Mirrors the strength plan schema enums; cycling has its own.
VALID_BODY_PARTS = {
    "legs", "chest", "back", "shoulders", "arms", "core", "full_body",
}
VALID_EQUIPMENT = {
    "machine", "barbell", "dumbbell", "cable", "bodyweight",
    "plate_loaded", "smith_machine", "other",
}
VALID_PLAN_TYPES = {"strength", "cycling"}
VALID_REGIONS = VALID_BODY_PARTS  # muscle_groups.region uses same enum


# MARK: - Field-level validators

def require_slug(p: dict, field: str) -> None:
    val = p.get(field)
    if not isinstance(val, str) or not SLUG_RE.match(val):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field} must be lowercase snake_case (got '{val}')",
        )


def require_str(p: dict, field: str) -> None:
    val = p.get(field)
    if not isinstance(val, str) or not val.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field} must be a non-empty string",
        )


def require_slug_list(values: list, field: str) -> None:
    """Every element must be a slug string.

    The route hashes these into a set to look the muscles up, so an
    unchecked dict or list element raises TypeError there instead of
    producing a 422 here.
    """
    if not all(isinstance(v, str) and SLUG_RE.match(v) for v in values):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field} must be an array of slug strings",
        )


def require_enum(p: dict, field: str, valid: set[str]) -> None:
    val = p.get(field)
    if val not in valid:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field} must be one of {sorted(valid)} (got '{val}')",
        )


# MARK: - Document-level validators

def validate_exercise_payload_shape(p: dict) -> None:
    """Validate everything about an exercise payload that does NOT require
    a database lookup. Muscle-slug existence is verified separately by the
    route handler (which has DB access)."""
    require_slug(p, "slug")
    require_str(p, "name")
    require_enum(p, "body_part", VALID_BODY_PARTS)
    require_enum(p, "equipment", VALID_EQUIPMENT)
    require_str(p, "movement_pattern")

    primary = p.get("primary_muscles")
    if not isinstance(primary, list) or not primary:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="primary_muscles must be a non-empty array",
        )
    require_slug_list(primary, "primary_muscles")
    secondary = p.get("secondary_muscles", [])
    if not isinstance(secondary, list):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="secondary_muscles must be an array",
        )
    require_slug_list(secondary, "secondary_muscles")

    aliases = p.get("aliases", [])
    if not isinstance(aliases, list) or not all(isinstance(a, str) for a in aliases):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="aliases must be an array of strings",
        )

    applies_to = p.get("applies_to", ["strength"])
    if not isinstance(applies_to, list) or not applies_to:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="applies_to must be a non-empty array",
        )
    for pt in applies_to:
        if pt not in VALID_PLAN_TYPES:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Unknown plan_type in applies_to: '{pt}'",
            )


def validate_muscle_payload(p: dict) -> None:
    require_slug(p, "slug")
    require_str(p, "name")
    require_enum(p, "region", VALID_REGIONS)
    antagonists = p.get("antagonist_slugs", [])
    if not isinstance(antagonists, list) or not all(
        isinstance(a, str) and SLUG_RE.match(a) for a in antagonists
    ):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="antagonist_slugs must be an array of slug strings",
        )
    aliases = p.get("aliases", [])
    if not isinstance(aliases, list) or not all(isinstance(a, str) for a in aliases):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="aliases must be an array of strings",
        )


# MARK: - Normalization

def normalize_exercise(p: dict) -> dict:
    return {
        "slug": p["slug"],
        "name": p["name"].strip(),
        "aliases": list(p.get("aliases", [])),
        "body_part": p["body_part"],
        "equipment": p["equipment"],
        "movement_pattern": p["movement_pattern"],
        "primary_muscles": list(p["primary_muscles"]),
        "secondary_muscles": list(p.get("secondary_muscles", [])),
        "applies_to": list(p.get("applies_to", ["strength"])),
    }


def normalize_muscle(p: dict) -> dict:
    return {
        "slug": p["slug"],
        "name": p["name"].strip(),
        "region": p["region"],
        "antagonist_slugs": list(p.get("antagonist_slugs", [])),
        "aliases": list(p.get("aliases", [])),
    }
