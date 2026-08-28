from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, EmailStr
from pymongo.errors import DuplicateKeyError

from app.auth import hash_password, verify_password, create_token
from app.database import get_db

router = APIRouter(tags=["auth"])


class AuthRequest(BaseModel):
    email: EmailStr
    password: str


class AuthResponse(BaseModel):
    token: str
    email: str


@router.post("/register", response_model=AuthResponse)
async def register(body: AuthRequest):
    try:
        result = await get_db().users.insert_one({
            "email": body.email,
            "password_hash": await hash_password(body.password),
        })
    except DuplicateKeyError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered",
        )
    user_id = str(result.inserted_id)
    token = create_token(user_id, body.email)
    return AuthResponse(token=token, email=body.email)


@router.post("/login", response_model=AuthResponse)
async def login(body: AuthRequest):
    user = await get_db().users.find_one({"email": body.email})
    if not user or not await verify_password(
        body.password, user["password_hash"]
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    user_id = str(user["_id"])
    token = create_token(user_id, body.email)
    return AuthResponse(token=token, email=body.email)
