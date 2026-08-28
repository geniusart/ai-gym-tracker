from pydantic_settings import BaseSettings
from pydantic import field_validator


class Settings(BaseSettings):
    mongodb_url: str = "mongodb://mongo:27017"
    mongodb_db: str = "ironlog"
    jwt_secret: str
    jwt_expire_days: int = 90
    jwt_refresh_threshold_days: int = 30
    # Comma-separated emails allowed to write globally shared resources
    # (the AI agent instructions). Everything else is per-user data and
    # needs no allowlist.
    admin_emails: str = ""

    model_config = {"env_prefix": "", "case_sensitive": False}

    @property
    def admin_email_set(self) -> set[str]:
        return {
            e.strip().lower()
            for e in self.admin_emails.split(",")
            if e.strip()
        }

    @field_validator("jwt_secret")
    @classmethod
    def validate_jwt_secret(cls, value: str) -> str:
        if not value or value == "change-me-in-production":
            raise ValueError("JWT_SECRET must be set to a non-placeholder value")
        return value


settings = Settings()
