from pathlib import Path
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

from app.auth import require_admin
from app.database import get_db

router = APIRouter(tags=["agent-instructions"])

_DOCKER_PLAN_IMPORT_PATH = Path("/docs/AI_AGENT_PLAN_IMPORT.md")
_LOCAL_PLAN_IMPORT_PATH = (
    Path(__file__).parents[3] / "docs" / "AI_AGENT_PLAN_IMPORT.md"
)
_PLAN_IMPORT_ID = "plan-import"
_PLAN_IMPORT_TITLE = "IronLog Plan Import Instructions for AI Agents"


class AgentInstructionUpdate(BaseModel):
    content: str
    title: str | None = None


@router.get("/agent-instructions")
async def list_agent_instructions(request: Request):
    base = str(request.base_url).rstrip("/")
    return {
        "instructions": [
            {
                "id": "plan-import",
                "title": _PLAN_IMPORT_TITLE,
                "formats": {
                    "markdown": f"{base}/agent-instructions/plan-import",
                    "json": f"{base}/agent-instructions/plan-import.json",
                },
                "live_references": {
                    "schemas": f"{base}/schema",
                    "strength_schema": f"{base}/schema?type=strength",
                    "cycling_schema": f"{base}/schema?type=cycling",
                    "strength_exercise_catalog": (
                        f"{base}/exercises/catalog?plan_type=strength"
                    ),
                    "exercise_docs_missing": (
                        f"{base}/exercise-docs/missing?locale=ru&status=reviewed"
                    ),
                    "muscle_groups": f"{base}/muscle-groups",
                },
            }
        ]
    }


@router.get(
    "/agent-instructions/plan-import",
    response_class=PlainTextResponse,
    summary="Plan import instructions for AI agents",
)
async def get_plan_import_instructions():
    instruction = await _read_plan_import_instructions()
    return PlainTextResponse(
        instruction["content"],
        media_type="text/markdown; charset=utf-8",
    )


@router.get(
    "/agent-instructions/plan-import.json",
    summary="Plan import instructions for AI agents as JSON",
)
async def get_plan_import_instructions_json(request: Request):
    base = str(request.base_url).rstrip("/")
    instruction = await _read_plan_import_instructions()
    return {
        "id": _PLAN_IMPORT_ID,
        "title": instruction["title"],
        "format": "markdown",
        "source": instruction["source"],
        "updated_at": instruction.get("updated_at"),
        "content": instruction["content"],
        "live_references": {
            "schemas": f"{base}/schema",
            "strength_schema": f"{base}/schema?type=strength",
            "cycling_schema": f"{base}/schema?type=cycling",
            "strength_exercise_catalog": (
                f"{base}/exercises/catalog?plan_type=strength"
            ),
            "exercise_docs": f"{base}/exercise-docs?locale=ru",
            "exercise_docs_missing_reviewed": (
                f"{base}/exercise-docs/missing?locale=ru&status=reviewed"
            ),
            "exercise_doc_by_slug": f"{base}/exercises/{{slug}}/docs?locale=ru",
            "muscle_groups": f"{base}/muscle-groups",
            "plans": f"{base}/plans",
            "upload_plan": f"{base}/plan",
        },
    }


@router.put(
    "/agent-instructions/plan-import",
    summary="Update plan import instructions",
)
async def update_plan_import_instructions(
    body: AgentInstructionUpdate,
    user: dict = Depends(require_admin),
):
    content = body.content.strip()
    if not content:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="content must be a non-empty string",
        )

    now = datetime.now(timezone.utc)
    title = body.title or _PLAN_IMPORT_TITLE
    doc = {
        "_id": _PLAN_IMPORT_ID,
        "title": title,
        "format": "markdown",
        "content": content,
        "updated_at": now,
        "updated_by": str(user.get("_id", "")),
    }
    await get_db().agent_instructions.update_one(
        {"_id": _PLAN_IMPORT_ID},
        {"$set": doc},
        upsert=True,
    )
    return {
        "id": _PLAN_IMPORT_ID,
        "title": title,
        "format": "markdown",
        "updated_at": now.isoformat(),
        "content_length": len(content),
    }


async def _read_plan_import_instructions() -> dict:
    db_doc = await _read_plan_import_from_db()
    if db_doc:
        return {
            "title": db_doc.get("title") or _PLAN_IMPORT_TITLE,
            "content": db_doc["content"],
            "source": "database",
            "updated_at": _isoformat(db_doc.get("updated_at")),
        }

    path = (
        _DOCKER_PLAN_IMPORT_PATH
        if _DOCKER_PLAN_IMPORT_PATH.exists()
        else _LOCAL_PLAN_IMPORT_PATH
    )
    try:
        return {
            "title": _PLAN_IMPORT_TITLE,
            "content": path.read_text(encoding="utf-8"),
            "source": "fallback_file",
            "updated_at": None,
        }
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Plan import instructions are not available",
        ) from exc


async def _read_plan_import_from_db() -> dict | None:
    db = get_db()
    if db is None or not hasattr(db, "agent_instructions"):
        return None
    doc = await db.agent_instructions.find_one({"_id": _PLAN_IMPORT_ID})
    if not doc or not isinstance(doc.get("content"), str) or not doc["content"].strip():
        return None
    return doc


def _isoformat(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value)
