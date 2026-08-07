# ─────────────────────────────────────────────────────────────────────────────
# app/main.py
#
# WHY: This is the application entry point — the single file that wires
#      everything together.  It is intentionally kept thin:
#
#        • App factory pattern (create_application()) — makes the app
#          importable and testable without side-effects at import time.
#        • Lifespan context manager — replaces deprecated on_event("startup").
#          Manages the httpx async client lifecycle so connections are pooled
#          and cleanly closed on shutdown (important for GKE pod termination).
#        • Middleware registration — order matters; logging wraps everything.
#        • Router inclusion — /health, /ready, /v1/... all registered here.
#        • OpenAPI metadata — professional docs at /docs for interview demos.
#
#      The `if __name__ == "__main__"` block enables running locally with
#      `python -m app.main` without needing a shell script.  In production,
#      the Docker CMD calls uvicorn directly (Phase 2).
# ─────────────────────────────────────────────────────────────────────────────

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.core import add_exception_handlers
from app.logging_config import setup_logging
from app.middleware.logging import RequestLoggingMiddleware
from app.routers import health, inference
from app.schemas import ErrorResponse, RootResponse

# Initialise structured logging FIRST — before any other imports emit logs.
setup_logging()

logger = logging.getLogger(__name__)


# ── Lifespan ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """
    Manage application-level resources that must be created once and shared
    across all requests.

    startup:
      • Creates the shared httpx.AsyncClient for vLLM communication.
        Connection pooling means we reuse TCP connections instead of
        establishing a new one for every inference request — critical for
        low-latency production traffic.

    shutdown:
      • Closes the httpx client gracefully so in-flight requests complete
        before the GKE pod terminates (respects terminationGracePeriodSeconds).
    """
    logger.info(
        "Application starting up",
        extra={
            "environment": settings.app_env,
            "version": settings.app_version,
            "vllm_backend": str(settings.vllm_base_url),
        },
    )

    # Create the shared async HTTP client
    http_client = httpx.AsyncClient(
        base_url=str(settings.vllm_base_url),
        timeout=httpx.Timeout(
            connect=5.0,
            read=float(settings.vllm_timeout_seconds),
            write=10.0,
            pool=5.0,
        ),
        limits=httpx.Limits(
            max_connections=100,
            max_keepalive_connections=20,
            keepalive_expiry=30,
        ),
        headers={"Content-Type": "application/json"},
    )

    # Store on app.state so routers can access it via request.app.state.http_client
    app.state.http_client = http_client

    logger.info("HTTP client pool initialised", extra={"vllm_base_url": str(settings.vllm_base_url)})

    yield  # ← application runs here

    # ── Shutdown ──────────────────────────────────────────────────────────
    logger.info("Application shutting down — closing HTTP client pool")
    await http_client.aclose()
    logger.info("Shutdown complete")


# ── Application factory ───────────────────────────────────────────────────────
def create_application() -> FastAPI:
    """
    Factory function that constructs and configures the FastAPI application.

    Using a factory (rather than a module-level `app = FastAPI(...)`) means:
      • Tests can call create_application() to get a fresh instance
      • The lifespan runs predictably in test contexts
      • No global state leaks between test cases
    """
    application = FastAPI(
        title="Mistral-7B Inference Gateway",
        description=(
            "Production FastAPI gateway for Mistral-7B-Instruct-v0.3 hosted on GKE. "
            "Proxies OpenAI-compatible requests to the vLLM backend running on GPU nodes."
        ),
        version=settings.app_version,
        docs_url="/docs",        # Swagger UI
        redoc_url="/redoc",      # ReDoc UI
        openapi_url="/openapi.json",
        lifespan=lifespan,
    )
    add_exception_handlers(application)

    # ── Middleware (order: last registered = outermost wrapper) ───────────
    # CORS — restrict in production via environment variable (Phase 3)
    application.add_middleware(
        CORSMiddleware,
        allow_origins=["*"] if not settings.is_production else [],
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["*"],
    )

    # Request logging — runs after CORS, wraps all route handlers
    application.add_middleware(RequestLoggingMiddleware)

    # ── Routers ───────────────────────────────────────────────────────────
    application.include_router(health.router)
    application.include_router(inference.router)

    # ── Root endpoint ─────────────────────────────────────────────────────
    @application.get(
        "/",
        summary="Root",
        description="Service identity endpoint. Returns name, version, and environment.",
        tags=["general"],
        response_model=RootResponse,
        responses={500: {"model": ErrorResponse}},
    )
    async def root() -> RootResponse:
        """
        Root endpoint — confirms the service is reachable and identifies itself.

        Useful for:
          • Quick sanity check after deployment
          • Service discovery by downstream consumers
          • Interview demo: curl https://<your-domain>/ → instant confirmation
        """
        return RootResponse(
            service="mistral-inference-gateway",
            version=settings.app_version,
            environment=settings.app_env,
            status="running",
            docs="/docs",
        )

    logger.info(
        "FastAPI application created",
        extra={
            "routes": len(application.routes),
            "environment": settings.app_env,
        },
    )

    return application


# ── Singleton app instance ─────────────────────────────────────────────────────
# `app` is what Uvicorn imports when running:
#   uvicorn app.main:app --host 0.0.0.0 --port 8000
app = create_application()


# ── Local development entry point ─────────────────────────────────────────────
if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        workers=settings.workers,
        reload=not settings.is_production,  # Hot-reload in dev only
        log_config=None,   # Disable Uvicorn's default logging — ours handles it
        access_log=False,  # Access logging is handled by RequestLoggingMiddleware
    )
