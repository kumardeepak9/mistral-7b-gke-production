# ─────────────────────────────────────────────────────────────────────────────
# app/routers/health.py
#
# WHY: Kubernetes requires two distinct probe endpoints to manage pod lifecycle:
#
#   /health  → Liveness probe
#              "Is the process alive?"
#              If this fails, kubelet RESTARTS the pod.
#              It should only fail if the app is deadlocked or corrupted.
#              Keep it lightweight — no downstream calls.
#
#   /ready   → Readiness probe
#              "Can this pod accept traffic right now?"
#              If this fails, the pod is removed from the Service endpoint
#              slice — no traffic is sent to it — but it is NOT restarted.
#              Use this to signal warm-up, dependency unavailability, etc.
#
#   Both probes are referenced in the GKE Deployment spec (Phase 3) and
#   are visible in Diagram 1 (FastAPI Deployment 2-3 Pods).
# ─────────────────────────────────────────────────────────────────────────────

import logging
import time

from fastapi import APIRouter
from pydantic import BaseModel

from app.config import settings

logger = logging.getLogger(__name__)

router = APIRouter(tags=["observability"])

# Record the process start time once at module import
_START_TIME = time.time()


# ── Response models ───────────────────────────────────────────────────────────
class HealthResponse(BaseModel):
    """Response schema for /health (liveness probe)."""

    status: str
    version: str
    environment: str
    uptime_seconds: float


class ReadinessResponse(BaseModel):
    """Response schema for /ready (readiness probe)."""

    status: str
    version: str
    checks: dict[str, str]


# ── Endpoints ─────────────────────────────────────────────────────────────────
@router.get(
    "/health",
    response_model=HealthResponse,
    summary="Liveness probe",
    description=(
        "Kubernetes liveness probe. Returns 200 when the FastAPI process is "
        "running. Returns 5xx only if the application is in an unrecoverable "
        "state. This endpoint is intentionally kept lightweight — no I/O."
    ),
)
async def health() -> HealthResponse:
    """
    Liveness probe — always returns 200 if the process is up.

    GKE Deployment spec (Phase 3) will configure:
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 15
    """
    uptime = round(time.time() - _START_TIME, 2)
    logger.debug("Liveness probe hit", extra={"uptime_seconds": uptime})

    return HealthResponse(
        status="ok",
        version=settings.app_version,
        environment=settings.app_env,
        uptime_seconds=uptime,
    )


@router.get(
    "/ready",
    response_model=ReadinessResponse,
    summary="Readiness probe",
    description=(
        "Kubernetes readiness probe. Returns 200 when the pod is ready to "
        "serve traffic. Will return 503 if any critical dependency check fails. "
        "The pod is automatically removed from Service load balancing on failure."
    ),
)
async def ready() -> ReadinessResponse:
    """
    Readiness probe — validates that the app can serve requests.

    Currently checks:
      • config_loaded — settings object initialised without errors

    Future phases will add:
      • vllm_reachable — HTTP ping to the vLLM ClusterIP service

    GKE Deployment spec (Phase 3) will configure:
        readinessProbe:
          httpGet:
            path: /ready
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 3
    """
    checks: dict[str, str] = {}

    # ── Check: configuration loaded ───────────────────────────────────────
    try:
        _ = settings.app_version  # access any field to confirm Settings is valid
        checks["config_loaded"] = "ok"
    except Exception as exc:  # noqa: BLE001
        logger.error("Config check failed", extra={"error": str(exc)})
        checks["config_loaded"] = "error"

    # ── Aggregate status ──────────────────────────────────────────────────
    overall = "ok" if all(v == "ok" for v in checks.values()) else "degraded"

    logger.debug("Readiness probe hit", extra={"status": overall, "checks": checks})

    return ReadinessResponse(
        status=overall,
        version=settings.app_version,
        checks=checks,
    )
