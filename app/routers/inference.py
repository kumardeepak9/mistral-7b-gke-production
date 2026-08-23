import logging
from collections.abc import AsyncIterator

import httpx
from fastapi import APIRouter, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse

from app.config import settings
from app.schemas import ChatCompletionRequest, ChatCompletionResponse, ErrorResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1", tags=["inference"])


def _build_upstream_headers(request: Request) -> dict[str, str]:
    headers: dict[str, str] = {"Content-Type": "application/json"}
    request_id = getattr(request.state, "request_id", None)
    if request_id:
        headers["X-Request-ID"] = request_id
    if "Authorization" in request.headers:
        headers["Authorization"] = request.headers["Authorization"]
    return headers


def _ensure_http_client(request: Request) -> httpx.AsyncClient:
    http_client = getattr(request.app.state, "http_client", None)
    if not isinstance(http_client, httpx.AsyncClient):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Inference backend client is not available",
        )
    return http_client


@router.post(
    "/chat/completions",
    summary="Chat completions (vLLM proxy)",
    description=(
        "Proxies an OpenAI-compatible chat completion request to the vLLM "
        "backend running on GPU nodes inside the GKE cluster."
    ),
    status_code=status.HTTP_200_OK,
    response_model=ChatCompletionResponse,
    responses={
        status.HTTP_422_UNPROCESSABLE_ENTITY: {"model": ErrorResponse},
        status.HTTP_500_INTERNAL_SERVER_ERROR: {"model": ErrorResponse},
        status.HTTP_502_BAD_GATEWAY: {"model": ErrorResponse},
        status.HTTP_503_SERVICE_UNAVAILABLE: {"model": ErrorResponse},
        status.HTTP_504_GATEWAY_TIMEOUT: {"model": ErrorResponse},
    },
)
async def chat_completions(
    request: Request,
    body: ChatCompletionRequest,
) -> Response | ChatCompletionResponse:
    if body.max_tokens > settings.max_tokens_limit:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"max_tokens ({body.max_tokens}) exceeds the server limit "
                f"of {settings.max_tokens_limit}."
            ),
        )

    request_id = getattr(request.state, "request_id", "unknown")
    http_client = _ensure_http_client(request)
    payload = body.model_dump(mode="json")
    headers = _build_upstream_headers(request)

    logger.info(
        "Forwarding inference request to vLLM",
        extra={
            "request_id": request_id,
            "model": body.model,
            "message_count": len(body.messages),
            "max_tokens": body.max_tokens,
            "stream": body.stream,
        },
    )

    if body.stream:
        return await _stream_chat_completions(
            http_client=http_client,
            payload=payload,
            headers=headers,
        )

    try:
        upstream_response = await http_client.post(
            "/v1/chat/completions",
            json=payload,
            headers=headers,
        )
    except httpx.TimeoutException as exc:
        logger.warning("vLLM upstream timed out", extra={"request_id": request_id})
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="vLLM upstream request timed out",
        ) from exc
    except httpx.RequestError as exc:
        logger.error(
            "vLLM upstream request error",
            extra={"request_id": request_id, "error": str(exc)},
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Unable to reach vLLM upstream",
        ) from exc

    if upstream_response.status_code >= 400:
        logger.warning(
            "vLLM upstream returned error response",
            extra={
                "request_id": request_id,
                "status_code": upstream_response.status_code,
            },
        )
        raise HTTPException(
            status_code=upstream_response.status_code,
            detail=upstream_response.text or "vLLM upstream request failed",
        )

    try:
        response_payload = upstream_response.json()
    except ValueError as exc:
        logger.error(
            "vLLM upstream returned non-JSON payload", extra={"request_id": request_id}
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="vLLM upstream returned an invalid response payload",
        ) from exc

    return ChatCompletionResponse.model_validate(response_payload)


async def _stream_chat_completions(
    *,
    http_client: httpx.AsyncClient,
    payload: dict[str, object],
    headers: dict[str, str],
) -> StreamingResponse:
    try:
        upstream_stream = http_client.stream(
            "POST",
            "/v1/chat/completions",
            json=payload,
            headers=headers,
        )
        stream_context = upstream_stream.__aenter__()
        upstream_response = await stream_context
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="vLLM upstream request timed out",
        ) from exc
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Unable to reach vLLM upstream",
        ) from exc

    if upstream_response.status_code >= 400:
        error_body = await upstream_response.aread()
        await upstream_stream.__aexit__(None, None, None)
        raise HTTPException(
            status_code=upstream_response.status_code,
            detail=error_body.decode("utf-8", errors="replace")
            or "vLLM upstream stream failed",
        )

    async def iterator() -> AsyncIterator[bytes]:
        try:
            async for chunk in upstream_response.aiter_bytes():
                if chunk:
                    yield chunk
        finally:
            await upstream_stream.__aexit__(None, None, None)

    passthrough_headers = {
        key: value
        for key, value in upstream_response.headers.items()
        if key.lower() in {"cache-control", "connection", "x-request-id"}
    }

    return StreamingResponse(
        iterator(),
        media_type=upstream_response.headers.get("content-type", "text/event-stream"),
        headers=passthrough_headers,
        status_code=upstream_response.status_code,
    )
