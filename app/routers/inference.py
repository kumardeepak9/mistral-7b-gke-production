# ─────────────────────────────────────────────────────────────────────────────
# app/routers/inference.py
#
# WHY: From Diagram 1, the FastAPI pods make "OpenAI API Calls" to the vLLM
#      Service (ClusterIP).  vLLM exposes an OpenAI-compatible REST API, so
#      this router acts as an authenticated, rate-limited proxy between the
#      GKE Ingress and the vLLM backend.
#
#      This file is a STUB in Phase 1.  It establishes:
#        • The correct URL prefix (/v1) that matches vLLM's OpenAI-compatible API
#        • The httpx async client lifecycle (created once, reused across requests)
#        • The request/response Pydantic schemas
#        • The proxy forwarding pattern (Phase 2 will complete the vLLM call)
#
#      Separating this into its own router keeps main.py clean and allows the
#      inference logic to be tested independently.
# ─────────────────────────────────────────────────────────────────────────────

import logging
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field

from app.config import settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1", tags=["inference"])

# ── Shared async HTTP client ──────────────────────────────────────────────────
# Created once and stored on app.state in main.py lifespan.
# Retrieved here via the Request object to avoid module-level state.
# This pattern ensures connection pooling is shared across all requests.


# ── Request / Response schemas ────────────────────────────────────────────────
class ChatMessage(BaseModel):
    """A single message in an OpenAI-compatible chat conversation."""

    role: str = Field(..., description="'system', 'user', or 'assistant'")
    content: str = Field(..., description="Message text content")


class ChatCompletionRequest(BaseModel):
    """
    OpenAI-compatible /v1/chat/completions request body.

    We validate max_tokens against settings.max_tokens_limit to prevent
    runaway inference costs — a production guard not present in raw vLLM.
    """

    model: str = Field(
        default_factory=lambda: settings.vllm_model_name,
        description="Model identifier. Defaults to the configured vLLM model.",
    )
    messages: list[ChatMessage] = Field(
        ...,
        min_length=1,
        description="Conversation history. Must contain at least one message.",
    )
    max_tokens: int = Field(
        default_factory=lambda: settings.default_max_tokens,
        ge=1,
        description="Maximum tokens to generate.",
    )
    temperature: float = Field(
        default=0.7,
        ge=0.0,
        le=2.0,
        description="Sampling temperature.",
    )
    stream: bool = Field(
        default=False,
        description="Streaming not yet implemented. Must be false in Phase 1.",
    )


class ChatCompletionResponse(BaseModel):
    """Passthrough of vLLM's OpenAI-compatible response."""

    # We return the raw vLLM JSON rather than re-validating it,
    # so the schema here is intentionally permissive.
    pass


# ── Endpoints ─────────────────────────────────────────────────────────────────
@router.post(
    "/chat/completions",
    summary="Chat completions (vLLM proxy)",
    description=(
        "Proxies an OpenAI-compatible chat completion request to the vLLM "
        "backend running on GPU nodes inside the GKE cluster. "
        "**Phase 1 stub** — returns a placeholder response until Phase 2."
    ),
    status_code=status.HTTP_200_OK,
)
async def chat_completions(
    request: Request,
    body: ChatCompletionRequest,
) -> Any:
    """
    Phase 1 stub for the vLLM proxy endpoint.

    Production behaviour (Phase 2):
      1. Validate and sanitise the incoming request
      2. Enforce max_tokens ceiling
      3. Forward to vLLM via httpx (reusing the shared client from app.state)
      4. Return vLLM's raw JSON response

    Currently returns a static placeholder so the endpoint is testable
    and OpenAPI docs are accurate.
    """
    # ── Guard: streaming not yet supported ────────────────────────────────
    if body.stream:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Streaming is not yet implemented. Set stream=false.",
        )

    # ── Guard: max_tokens ceiling ─────────────────────────────────────────
    if body.max_tokens > settings.max_tokens_limit:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"max_tokens ({body.max_tokens}) exceeds the server limit "
                f"of {settings.max_tokens_limit}."
            ),
        )

    request_id = getattr(request.state, "request_id", "unknown")
    logger.info(
        "Inference request received (Phase 1 stub)",
        extra={
            "request_id": request_id,
            "model": body.model,
            "message_count": len(body.messages),
            "max_tokens": body.max_tokens,
        },
    )

    # ── Phase 1 stub response — replaced in Phase 2 ───────────────────────
    return {
        "id": f"chatcmpl-stub-{request_id}",
        "object": "chat.completion",
        "model": body.model,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": (
                        "[Phase 1 stub] vLLM proxy not yet wired. "
                        "This endpoint will forward to the vLLM ClusterIP "
                        f"at {settings.vllm_base_url} in Phase 2."
                    ),
                },
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }
