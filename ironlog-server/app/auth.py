from datetime import datetime, timedelta, timezone

from bson import ObjectId
from bson.errors import InvalidId
from fastapi import Depends, HTTPException, Response, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from starlette.concurrency import run_in_threadpool

from app.config import settings
from app.database import get_db

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
bearer_scheme = HTTPBearer()


async def hash_password(password: str) -> str:
    """bcrypt on a worker thread.

    Hashing costs ~250 ms of CPU at the default cost factor, and the app
    runs as a single uvicorn worker: calling it inline would stall every
    concurrent request -- log sync, analytics, health checks -- for that
    whole time.
    """
    return await run_in_threadpool(pwd_context.hash, password)


async def verify_password(plain: str, hashed: str) -> bool:
    """bcrypt verification on a worker thread. See `hash_password`."""
    return await run_in_threadpool(pwd_context.verify, plain, hashed)


def create_token(user_id: str, email: str) -> str:
    exp = datetime.now(timezone.utc) + timedelta(days=settings.jwt_expire_days)
    payload = {"user_id": user_id, "email": email, "exp": exp}
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        )


def maybe_refresh_token(payload: dict) -> str | None:
    """Return a fresh token if the current one expires within the threshold."""
    exp = datetime.fromtimestamp(payload["exp"], tz=timezone.utc)
    remaining = exp - datetime.now(timezone.utc)
    if remaining < timedelta(days=settings.jwt_refresh_threshold_days):
        return create_token(payload["user_id"], payload["email"])
    return None


def attach_refreshed_token(user: dict, response: Response | None) -> None:
    """Put a rolling-refreshed JWT on the response when one is due.

    Lives here next to `maybe_refresh_token` rather than being copied into
    each router: a route module that forgets its own copy silently stops
    refreshing, and the client only learns about it when the token expires.
    """
    payload = user.get("_token_payload")
    if payload and response is not None:
        new_token = maybe_refresh_token(payload)
        if new_token:
            response.headers["X-Refreshed-Token"] = new_token


async def get_current_user(
    creds: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    ) -> dict:
    payload = decode_token(creds.credentials)
    try:
        user_id = ObjectId(payload["user_id"])
    except (KeyError, TypeError, InvalidId):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
        )
    user = await get_db().users.find_one({"_id": user_id})
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
        )
    user["_id"] = str(user["_id"])
    user["_token_payload"] = payload
    return user


async def require_admin(user: dict = Depends(get_current_user)) -> dict:
    """Authorize writes to resources shared by every user.

    Per-user collections are already scoped by `user_id`, but the agent
    instructions are global and are served unauthenticated -- so anyone who
    could write them could feed arbitrary text to the AI agent that authors
    training plans. Membership comes from the ADMIN_EMAILS setting or an
    `is_admin` flag on the user document; with neither configured, nobody
    is an admin and these endpoints stay closed.
    """
    email = (user.get("email") or "").strip().lower()
    if user.get("is_admin") is True or (
        email and email in settings.admin_email_set
    ):
        return user
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=(
            "Admin privileges required. Set ADMIN_EMAILS on the server or "
            "is_admin on the user document."
        ),
    )
