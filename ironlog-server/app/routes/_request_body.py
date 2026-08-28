"""Shared request-body parsing for routes that take raw JSON.

Several endpoints accept a free-form JSON object instead of a pydantic
model (plans and logs, whose shape is owned by `schemas/`, and the catalog
writers, which validate through `_catalog_validators`). Each one used to
carry its own `try / await request.json() / isinstance(dict)` block, and
they had drifted: some caught `ValueError`, some `Exception`, some
answered 400 and some 422, and four of them caught nothing at all -- a
malformed body there surfaced as a 500 with a stack trace.

Routing every such handler through one helper keeps the error contract
identical no matter which endpoint the client hit.
"""

from fastapi import HTTPException, Request, status


async def read_json_object(request: Request, what: str = "Body") -> dict:
    """Parse the request body as a JSON object, or raise 422.

    `what` names the payload in the error message (e.g. "Plan body").
    """
    try:
        data = await request.json()
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Invalid JSON body",
        )
    if not isinstance(data, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{what} must be a JSON object",
        )
    return data


async def read_optional_json_object(request: Request) -> dict:
    """Same, but an empty or unparseable body yields `{}`.

    For endpoints whose body is entirely optional (PATCH .../deprecate).
    """
    try:
        data = await request.json()
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}
