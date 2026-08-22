# ─────────────────────────────────────────────────────────────────────────────
# app/config.py
#
# WHY: Centralises ALL configuration in one typed, validated object.
#      pydantic-settings reads from environment variables (and optionally a
#      .env file in development).  In production (GKE), the same variables are
#      injected via Kubernetes ConfigMaps / Secrets — no code change needed.
#
#      Benefits over raw os.environ:
#        • Type coercion  — PORT="8000" becomes int automatically
#        • Validation     — missing required vars raise a clear error at startup
#        • Documentation  — Field(description=...) serves as inline docs
#        • Testability    — tests can override settings without patching os.environ
# ─────────────────────────────────────────────────────────────────────────────

from typing import Literal

from pydantic import AnyHttpUrl, Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """
    Application-wide configuration loaded from environment variables.

    All fields have defaults so the app starts cleanly in development.
    Production values are always injected from outside (never hardcoded).
    """

    model_config = SettingsConfigDict(
        # Load .env file only in development; ignored when running in a container
        # because the file is excluded by .dockerignore.
        env_file=".env",
        env_file_encoding="utf-8",
        # Extra env vars that don't match a field are silently ignored
        # (avoids noise from system-level variables like PATH, HOME, etc.)
        extra="ignore",
        # Cache the parsed settings object — reading env vars is cheap but
        # validation runs only once per process.
        case_sensitive=False,
    )

    # ── Application ──────────────────────────────────────────────────────────
    app_env: Literal["development", "staging", "production"] = Field(
        default="development",
        description="Runtime environment: development | staging | production",
    )
    app_version: str = Field(
        default="0.1.0",
        description="Semantic version injected by CI during Docker build",
    )
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = Field(
        default="INFO",
        description="Python logging level: DEBUG | INFO | WARNING | ERROR | CRITICAL",
    )

    # ── Server ───────────────────────────────────────────────────────────────
    host: str = Field(
        default="0.0.0.0",
        description="Bind address. Always 0.0.0.0 inside a container.",
    )
    port: int = Field(
        default=8000,
        ge=1,
        le=65535,
        description="Uvicorn listen port. Must match containerPort in GKE Deployment spec.",
    )
    workers: int = Field(
        default=1,
        ge=1,
        description="Number of Uvicorn worker processes. Set >= 1 per CPU core in prod.",
    )

    # ── vLLM Backend ─────────────────────────────────────────────────────────
    vllm_base_url: AnyHttpUrl = Field(
        default="http://vllm-service:8001",
        description="ClusterIP URL of the vLLM service inside the GKE cluster.",
    )
    vllm_model_name: str = Field(
        default="mistralai/Mistral-7B-Instruct-v0.3",
        description="Model identifier forwarded in every OpenAI-compatible request.",
    )
    vllm_timeout_seconds: int = Field(
        default=120,
        ge=1,
        description="Max seconds to wait for vLLM to return a completion.",
    )

    # ── Request Limits ───────────────────────────────────────────────────────
    max_tokens_limit: int = Field(
        default=4096,
        ge=1,
        description="Hard ceiling on max_tokens to prevent runaway inference costs.",
    )
    default_max_tokens: int = Field(
        default=512,
        ge=1,
        description="Default max_tokens when the caller does not supply one.",
    )

    # ── Validators ───────────────────────────────────────────────────────────
    @field_validator("log_level")
    @classmethod
    def validate_log_level(cls, v: str) -> str:
        allowed = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
        upper = v.upper()
        if upper not in allowed:
            raise ValueError(f"log_level must be one of {allowed}, got '{v}'")
        return upper

    @model_validator(mode="after")
    def validate_token_defaults(self) -> "Settings":
        if self.default_max_tokens > self.max_tokens_limit:
            raise ValueError(
                "default_max_tokens must be less than or equal to max_tokens_limit"
            )
        return self

    # ── Derived properties ───────────────────────────────────────────────────
    @property
    def is_production(self) -> bool:
        """Convenience flag used by logging and middleware."""
        return self.app_env == "production"


# ── Singleton ────────────────────────────────────────────────────────────────
# Instantiate once at import time so the entire application shares one object.
# Kubernetes injects env vars before the process starts, so this is safe.
settings = Settings()
