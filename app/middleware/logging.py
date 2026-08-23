# ─────────────────────────────────────────────────────────────────────────────
# app/middleware/logging.py
#
# WHY: FastAPI's default access log (from Uvicorn) is a single plain-text line
#      that cannot be enriched with application context. This middleware runs
#      around every request and emits a structured JSON log line that includes:
#
#        • request_id   — unique per-request UUID for trace correlation
#        • method, path, status_code
#        • duration_ms  — end-to-end latency visible in Grafana dashboards
#        • client_ip    — respects X-Forwarded-For from Cloud Armor / Load Balancer
#
#      This satisfies the observability requirement visible in Diagram 3
#      (Prometheus / Grafana stack).  Prometheus metrics scraping will be added
#      in a later phase; this middleware is the logging half.
# ─────────────────────────────────────────────────────────────────────────────

import logging
import time
import uuid

from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response
from starlette.status import HTTP_500_INTERNAL_SERVER_ERROR

logger = logging.getLogger(__name__)


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    """
    ASGI middleware that wraps every request/response cycle with structured
    JSON logging.

    Assigns a unique `X-Request-ID` to each request (generated if the caller
    does not supply one) and includes it in both the response header and the
    log line — enabling distributed trace correlation across the FastAPI →
    vLLM call chain.
    """

    # Paths to skip — health/ready probes generate high-frequency noise
    _SKIP_PATHS: frozenset[str] = frozenset({"/health", "/ready", "/metrics"})

    async def dispatch(
        self,
        request: Request,
        call_next: RequestResponseEndpoint,
    ) -> Response:
        # ── Request ID ───────────────────────────────────────────────────────
        # Honour an incoming ID (e.g., from API Gateway or upstream service)
        # so the trace can be correlated end-to-end.
        request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())

        # Store on request state so route handlers can access it
        request.state.request_id = request_id

        # Resolve client IP — behind GCP Load Balancer / Cloud Armor the real
        # IP is in X-Forwarded-For, not request.client.host
        forwarded_for = request.headers.get("X-Forwarded-For")
        client_ip = (
            forwarded_for.split(",")[0].strip()
            if forwarded_for
            else (request.client.host if request.client else "unknown")
        )

        # ── Skip health probes ────────────────────────────────────────────────
        if request.url.path in self._SKIP_PATHS:
            response = await call_next(request)
            response.headers["X-Request-ID"] = request_id
            return response

        # ── Timing ───────────────────────────────────────────────────────────
        start_time = time.perf_counter()

        # ── Execute request ───────────────────────────────────────────────────
        try:
            response = await call_next(request)
        except Exception:
            duration_ms = round((time.perf_counter() - start_time) * 1000, 2)
            logger.exception(
                "request failed with unhandled exception",
                extra={
                    "request_id": request_id,
                    "method": request.method,
                    "path": request.url.path,
                    "status_code": HTTP_500_INTERNAL_SERVER_ERROR,
                    "duration_ms": duration_ms,
                    "client_ip": client_ip,
                    "user_agent": request.headers.get("User-Agent", ""),
                },
            )
            raise

        duration_ms = round((time.perf_counter() - start_time) * 1000, 2)

        # ── Structured log line ───────────────────────────────────────────────
        log_method = logger.info if response.status_code < 500 else logger.error
        log_method(
            "request completed",
            extra={
                "request_id": request_id,
                "method": request.method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": duration_ms,
                "client_ip": client_ip,
                "user_agent": request.headers.get("User-Agent", ""),
            },
        )

        # ── Propagate request ID in response headers ──────────────────────────
        response.headers["X-Request-ID"] = request_id

        return response
