from fastapi import HTTPException, status

REQUIRED_FIELDS = ["plan_type", "plan_id", "plan_version", "plan_name", "schema", "created_at"]


def validate_base(data: dict) -> None:
    """Validate base plan fields present in the request body."""
    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Missing required fields: {', '.join(missing)}",
        )

    if not isinstance(data["plan_name"], str) or not data["plan_name"].strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="plan_name must be a non-empty string",
        )

    if not isinstance(data["plan_id"], str) or not data["plan_id"].strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="plan_id must be a non-empty string",
        )

    if (
        isinstance(data["plan_version"], bool)
        or not isinstance(data["plan_version"], int)
        or data["plan_version"] < 1
    ):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="plan_version must be a positive integer",
        )

    # plan_type is used as a dict key against SCHEMA_REGISTRY straight
    # after this call, so an unhashable value here becomes a TypeError
    # and a 500 rather than the 422 the caller is meant to get.
    if not isinstance(data["plan_type"], str) or not data["plan_type"].strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="plan_type must be a non-empty string",
        )

    if not isinstance(data["schema"], str) or not data["schema"].strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="schema must be a non-empty string",
        )
