"""Pure-Python validation helpers for exercise documentation payloads."""

import re
from urllib.parse import urlparse

from fastapi import HTTPException, status

from app.routes._catalog_validators import SLUG_RE

# \Z, not $: "$" also matches before a trailing newline, and locale is
# half of the unique (exercise_slug, locale) key -- "ru\n" would create
# a second document that no locale=ru read ever returns.
LOCALE_RE = re.compile(r"^[a-z]{2}(-[A-Z]{2})?\Z")
VALID_DOC_STATUSES = {"draft", "reviewed", "deprecated"}
VALID_MEDIA_KINDS = {"image", "video", "animation"}
VALID_MEDIA_LICENSES = {"owned", "cc", "public_domain"}
VALID_SOURCE_TYPES = {
    "government_guideline",
    "professional_guideline",
    "exercise_library",
    "research",
    "manufacturer",
    "other",
}


def validate_locale(locale: str) -> None:
    if not isinstance(locale, str) or not LOCALE_RE.match(locale):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="locale must look like 'ru' or 'en-US'",
        )


def validate_exercise_doc_payload_shape(payload: dict) -> None:
    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="exercise doc payload must be an object",
        )
    _require_str(payload, "title")
    _require_str(payload, "summary")
    _require_str(payload, "breathing")
    _require_string_list(payload, "setup", min_items=1)
    _require_string_list(payload, "execution", min_items=1)
    _require_string_list(payload, "cues", min_items=1)
    _require_string_list(payload, "common_mistakes", min_items=1)
    _require_string_list(payload, "safety_notes", min_items=1)
    _validate_status(payload.get("status", "draft"))
    _validate_alternative_slugs(payload.get("alternative_slugs", []))
    _validate_replaced_by(payload.get("status", "draft"), payload.get("replaced_by"))
    _validate_media(payload.get("media", []))
    _validate_sources(payload.get("sources", []))


def normalize_exercise_doc(payload: dict) -> dict:
    return {
        "title": payload["title"].strip(),
        "summary": payload["summary"].strip(),
        "setup": _clean_string_list(payload.get("setup", [])),
        "execution": _clean_string_list(payload.get("execution", [])),
        "breathing": payload["breathing"].strip(),
        "cues": _clean_string_list(payload.get("cues", [])),
        "common_mistakes": _clean_string_list(payload.get("common_mistakes", [])),
        "safety_notes": _clean_string_list(payload.get("safety_notes", [])),
        "alternative_slugs": list(payload.get("alternative_slugs", [])),
        "replaced_by": payload.get("replaced_by"),
        "media": [_normalize_media_item(item) for item in payload.get("media", [])],
        "sources": [_normalize_source_item(item) for item in payload.get("sources", [])],
        "status": payload.get("status", "draft"),
    }


def _require_str(payload: dict, field: str) -> None:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field} must be a non-empty string",
        )


def _require_string_list(payload: dict, field: str, min_items: int) -> None:
    values = payload.get(field)
    if (
        not isinstance(values, list)
        or len(values) < min_items
        or not all(isinstance(value, str) and value.strip() for value in values)
    ):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field} must be an array of non-empty strings",
        )


def _clean_string_list(values: list[str]) -> list[str]:
    return [value.strip() for value in values]


def _validate_status(value: str) -> None:
    if value not in VALID_DOC_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"status must be one of {sorted(VALID_DOC_STATUSES)}",
        )


def _validate_alternative_slugs(values: list) -> None:
    if not isinstance(values, list) or not all(
        isinstance(value, str) and SLUG_RE.match(value) for value in values
    ):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="alternative_slugs must be an array of exercise slugs",
        )


def _validate_replaced_by(status_value: str, value: object) -> None:
    if value is None:
        return
    if status_value != "deprecated":
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="replaced_by is allowed only when status is deprecated",
        )
    if not isinstance(value, str) or not SLUG_RE.match(value):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="replaced_by must be an exercise slug",
        )


def _validate_media(values: list) -> None:
    if not isinstance(values, list):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="media must be an array",
        )
    for item in values:
        if not isinstance(item, dict):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="media items must be objects",
            )
        if item.get("kind") not in VALID_MEDIA_KINDS:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"media.kind must be one of {sorted(VALID_MEDIA_KINDS)}",
            )
        _require_item_url(item, "media.url")
        _require_item_str(item, "alt", "media.alt")
        _require_item_str(item, "source", "media.source")
        _require_item_str(item, "license", "media.license")
        if item["license"] not in VALID_MEDIA_LICENSES:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"media.license must be one of {sorted(VALID_MEDIA_LICENSES)}",
            )


def _validate_sources(values: list) -> None:
    if not isinstance(values, list) or not values:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="sources must be a non-empty array",
        )
    for item in values:
        if not isinstance(item, dict):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="sources items must be objects",
            )
        _require_item_str(item, "title", "sources.title")
        _require_item_str(item, "publisher", "sources.publisher")
        _require_item_url(item, "sources.url")
        source_type = item.get("type", "other")
        if source_type not in VALID_SOURCE_TYPES:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"sources.type must be one of {sorted(VALID_SOURCE_TYPES)}",
            )


def _normalize_media_item(item: dict) -> dict:
    return {
        "kind": item["kind"],
        "url": item["url"].strip(),
        "alt": item["alt"].strip(),
        "source": item["source"].strip(),
        "license": item["license"].strip(),
        "attribution": str(item.get("attribution", "")).strip(),
    }


def _normalize_source_item(item: dict) -> dict:
    return {
        "title": item["title"].strip(),
        "publisher": item["publisher"].strip(),
        "url": item["url"].strip(),
        "type": item.get("type", "other"),
        "notes": str(item.get("notes", "")).strip(),
    }


def _require_item_str(item: dict, field: str, label: str) -> None:
    value = item.get(field)
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{label} must be a non-empty string",
        )


def _require_item_url(item: dict, label: str) -> None:
    value = item.get("url")
    parsed = urlparse(value) if isinstance(value, str) else None
    if not parsed or parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{label} must be an absolute http(s) URL",
        )
