from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query, Request, Response

from app.auth import attach_refreshed_token, get_current_user
from app.database import get_db
from app.routes._request_body import read_json_object

router = APIRouter(tags=["crash"])


@router.post("/crash")
async def post_crash(
    request: Request,
    user: dict = Depends(get_current_user),
    response: Response = None,
):
    """Receive a crash report from the client and store it.

    The body is whatever JSON the client produced. We do not validate
    field-by-field: the goal is to capture as much as possible even
    if the format evolves. We only enforce that the body is an object.
    """
    attach_refreshed_token(user, response)

    data = await read_json_object(request, "Crash report body")

    doc = {
        **data,
        "user_id": user["_id"],
        "received_at": datetime.now(timezone.utc).isoformat(),
    }
    if device_id := request.headers.get("X-Device-Id"):
        doc["device_id"] = device_id
    if user_agent := request.headers.get("User-Agent"):
        doc["user_agent"] = user_agent

    await get_db().crash_logs.insert_one(doc)
    doc.pop("_id", None)
    return {"ok": True, "id": data.get("id")}


@router.get("/crashes")
async def list_crashes(
    limit: int = Query(default=50, ge=1, le=200),
    user: dict = Depends(get_current_user),
    response: Response = None,
):
    """List recent crash reports for the current user."""
    attach_refreshed_token(user, response)

    cursor = get_db().crash_logs.find(
        {"user_id": user["_id"]},
        sort=[("received_at", -1)],
    ).limit(limit)

    results = []
    async for doc in cursor:
        doc.pop("_id", None)
        doc.pop("user_id", None)
        results.append(doc)
    return results

