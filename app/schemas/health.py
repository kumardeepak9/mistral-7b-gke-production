from typing import Literal

from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: Literal["ok"] = Field(description="Liveness status")
    version: str = Field(description="Service version")
    environment: str = Field(description="Runtime environment")
    uptime_seconds: float = Field(description="Process uptime in seconds")


class ReadinessResponse(BaseModel):
    status: Literal["ok"] = Field(description="Readiness status")
    version: str = Field(description="Service version")
    checks: dict[str, Literal["ok"]] = Field(description="Readiness checks")
