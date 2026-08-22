from pydantic import BaseModel, Field


class RootResponse(BaseModel):
    service: str = Field(description="Service identifier")
    version: str = Field(description="Application version")
    environment: str = Field(description="Runtime environment")
    status: str = Field(description="Service status")
    docs: str = Field(description="OpenAPI docs path")


class ErrorResponse(BaseModel):
    detail: str = Field(description="Human-readable error message")
    request_id: str | None = Field(
        default=None,
        description="Correlation ID for tracing the failing request",
    )
