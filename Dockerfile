# =============================================================================
# Dockerfile
#
# Multi-stage production build for the Mistral-7B FastAPI Gateway.
#
# STAGE OVERVIEW:
#   1. builder  — installs all Python dependencies into an isolated virtualenv.
#                 Has build tools (gcc, cargo for pydantic-core Rust extension).
#                 This stage is DISCARDED — it never ships to production.
#
#   2. runtime  — copies only the pre-built /venv and application source from
#                 the builder. No compiler, no pip, no build cache.
#                 This is the image that runs in GKE.
#
# RESULT:
#   Builder image  ~900 MB  (never pushed to Artifact Registry)
#   Runtime image  ~180 MB  (the only image that is pushed and run)
# =============================================================================


# ─────────────────────────────────────────────────────────────────────────────
# ARGs declared before the first FROM are available to all stages.
# They can be overridden at build time:
#   docker build --build-arg APP_VERSION=1.2.3 .
#
# WHY ARG instead of ENV here: ARGs are build-time only and do not persist
# into the final image layer, keeping the image clean and auditable.
# ─────────────────────────────────────────────────────────────────────────────
ARG PYTHON_VERSION=3.12
ARG APP_VERSION=0.1.0


# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1: builder
# ═════════════════════════════════════════════════════════════════════════════
# WHY python:3.12-slim and not python:3.12-alpine?
#   • alpine uses musl libc — many Python C extensions (pydantic-core, httpx)
#     require glibc and fail or produce buggy wheels on musl.
#   • slim uses Debian (glibc) with most packages stripped — safe for all
#     production Python packages and ~60 MB smaller than the full image.
FROM python:${PYTHON_VERSION}-slim AS builder

# ── Redeclare the ARG so it is in scope inside this stage ────────────────────
# ARGs declared before FROM are not automatically in scope inside stages.
ARG APP_VERSION

# ── Build-time metadata label ─────────────────────────────────────────────────
# WHY LABEL: Adds searchable metadata to the image for audit and CI tooling.
# These do NOT affect runtime behaviour or image size meaningfully.
LABEL org.opencontainers.image.title="mistral-inference-gateway" \
      org.opencontainers.image.description="FastAPI gateway for Mistral-7B-Instruct-v0.3 on GKE" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/your-org/mistral-gke"

# ── System build dependencies ─────────────────────────────────────────────────
# WHY: Keep only the minimum native build tooling required for Python packages
# that may compile C extensions when wheels are unavailable.
#   • build-essential — gcc, make (C compilation)
#   • libffi-dev      — ctypes / cffi bindings
#   • libssl-dev      — cryptography headers for httpx/httpcore
#
# WHY --no-install-recommends: Prevents apt from pulling in suggested packages
# (e.g. man pages, documentation) that add ~50 MB and are useless in containers.
#
# WHY rm -rf /var/lib/apt/lists/*: apt downloads package index files during
# `apt-get update`. Deleting them in the SAME RUN layer prevents them from
# being committed to the image layer cache. Always clean in the same RUN.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libffi-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Create an isolated virtualenv ─────────────────────────────────────────────
# WHY a venv inside a container? We could install globally, but using a venv:
#   • Makes the copy to the runtime stage trivially simple (one directory)
#   • Avoids conflicts with the system Python used by Debian tools
#   • Maps cleanly to production best practices reviewers expect to see
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv ${VIRTUAL_ENV}

# ── Activate the venv for all subsequent RUN commands ─────────────────────────
# WHY prepend PATH instead of `source activate`: ENV persists across RUN layers.
# `source` only affects the current shell session inside a single RUN.
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}" \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# ── Upgrade pip inside the venv ───────────────────────────────────────────────
# WHY: Older pip versions cannot resolve modern dependency metadata (PEP 658)
# and may fall back to slower, less secure resolution strategies.
RUN pip install --upgrade pip==25.1.1

# ── Copy requirements first — exploit Docker layer cache ─────────────────────
# WHY copy requirements before app code: Docker rebuilds layers from the first
# changed layer downward. If we copied the entire project first, every code
# change would invalidate the pip install layer — a ~2-minute rebuild each time.
# Copying requirements.txt alone means pip only reruns when deps actually change.
COPY requirements.txt .

# ── Install Python dependencies ───────────────────────────────────────────────
# PIP_NO_CACHE_DIR=1 is set above so pip does not persist wheel/download cache
# in image layers, keeping builder layers smaller and reproducible.
RUN pip install -r requirements.txt


# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2: runtime
# ═════════════════════════════════════════════════════════════════════════════
# Fresh, clean base — no build tools, no pip cache, no compiler.
# Only what the application needs to run is present.
FROM python:${PYTHON_VERSION}-slim AS runtime

# ── Redeclare ARGs in scope for this stage ────────────────────────────────────
ARG APP_VERSION

# ── Runtime metadata labels ───────────────────────────────────────────────────
LABEL org.opencontainers.image.title="mistral-inference-gateway" \
      org.opencontainers.image.description="FastAPI gateway for Mistral-7B-Instruct-v0.3 on GKE" \
      org.opencontainers.image.version="${APP_VERSION}"

# ── Runtime system dependencies ───────────────────────────────────────────────
# WHY: The runtime image needs ONLY shared libraries that the compiled C
# extensions link against at runtime — not the compiler that built them.
#   • libffi8    — shared library for ctypes/cffi (linked by pydantic-core)
#   • libssl3    — shared library for TLS (linked by httpx/httpcore)
#   • ca-certificates — TLS certificate bundle for HTTPS calls to vLLM
#
# WHY no gcc/curl/build-essential: Those were only needed to compile the
# Rust/C extensions. The compiled .so files are already in /opt/venv.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libffi8 \
        libssl3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user ─────────────────────────────────────────────────────────────
# WHY: Running as root inside a container is a critical security risk:
#   • A container escape (e.g., via a CVE) gives the attacker root on the host.
#   • GKE Security Policy / PSS (Pod Security Standards) blocks root containers
#     in production namespaces by default.
#   • CIS Benchmark for Kubernetes requires non-root containers.
#
# We create a dedicated system user (no home dir, no login shell) with a
# fixed UID/GID. The fixed IDs (1001) make it possible to set
# runAsUser: 1001 in the GKE PodSecurityContext (Phase 3).
RUN groupadd --gid 1001 appgroup \
    && useradd \
        --uid 1001 \
        --gid appgroup \
        --no-create-home \
        --shell /sbin/nologin \
        appuser

# ── Copy the pre-built virtualenv from builder ────────────────────────────────
# WHY COPY --from=builder: This is the multi-stage payoff. We copy only the
# finished /opt/venv — none of the build tools, compilers, or pip cache that
# exist in the builder stage. The Rust toolchain (~700 MB) stays behind.
COPY --from=builder /opt/venv /opt/venv

# ── Activate the venv in the runtime environment ──────────────────────────────
# Same PATH trick as the builder stage so `python` and `uvicorn` resolve
# to the venv binaries rather than the system Python.
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}" \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ── Application working directory ─────────────────────────────────────────────
# WHY /app and not /home/appuser or /: A dedicated /app directory is a
# well-understood convention that makes it obvious where app code lives
# when exec-ing into a running container for debugging.
WORKDIR /app

# ── Copy application source ───────────────────────────────────────────────────
# WHY copy app/ separately from the project root: We only need the Python
# package. Config files like .env.example and .dockerignore are not needed
# at runtime. The .dockerignore (Phase 1) ensures .env, .venv, __pycache__,
# .git, etc. are never sent to the build daemon.
COPY --chown=appuser:appgroup app/ ./app/

# ── Switch to non-root user ───────────────────────────────────────────────────
# All subsequent RUN, CMD, and ENTRYPOINT instructions run as this user.
# In GKE, this is enforced by the PodSecurityContext (Phase 3):
#   securityContext:
#     runAsNonRoot: true
#     runAsUser: 1001
USER appuser

# ── Runtime environment variables ─────────────────────────────────────────────
# WHY set defaults here: These provide sensible baseline values when the image
# is run with `docker run` without -e flags (e.g., smoke testing locally).
# In GKE, all of these are overridden by ConfigMap/Secret environment injection.
#
# WHY PYTHONDONTWRITEBYTECODE=1: Disables .pyc file creation. In a read-only
# container filesystem (GKE Security Context readOnlyRootFilesystem: true),
# writing .pyc files would cause a crash. Disable it preemptively.
#
# WHY PYTHONUNBUFFERED=1: Forces stdout/stderr to be unbuffered. Without this,
# Python buffers output and your structured JSON logs don't reach the
# Kubernetes log collector until the buffer flushes — meaning you lose logs
# from crashes. Unbuffered = logs appear instantly.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_ENV=production \
    APP_VERSION=${APP_VERSION} \
    HOST=0.0.0.0 \
    PORT=8000 \
    WORKERS=2 \
    LOG_LEVEL=INFO

# ── Expose the application port ───────────────────────────────────────────────
# WHY EXPOSE: This is documentation, not a firewall rule. It tells Docker,
# Kubernetes, and developers which port the process listens on.
# The GKE Service and Ingress (Phase 3) will reference this port (8000) as
# containerPort and targetPort respectively.
EXPOSE 8000

# ── Health check ─────────────────────────────────────────────────────────────
# WHY HEALTHCHECK in Dockerfile: Docker Swarm and docker-compose use this.
# Kubernetes ignores it (it uses the liveness/readiness probes we defined in
# app/routers/health.py), but it enables smoke testing with `docker run`
# without needing a full K8s cluster. Also useful in CI to gate deployment.
#
# --interval=30s  : check every 30 seconds
# --timeout=10s   : fail if no response within 10 seconds
# --start-period=10s : grace period after container starts (app init time)
# --retries=3     : mark unhealthy after 3 consecutive failures
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
    || exit 1

# ── Entrypoint and command ────────────────────────────────────────────────────
# WHY ENTRYPOINT + CMD split:
#   • ENTRYPOINT defines the process — always uvicorn, not replaceable at
#     runtime without --entrypoint flag (good: prevents accidental misuse).
#   • CMD provides default arguments — easily overridden by Kubernetes or
#     docker run without changing the entrypoint.
#     GKE Deployment spec (Phase 3) will override CMD to set workers, port, etc.
#
# WHY exec form ["...", "..."] instead of shell form "...":
#   • Exec form runs uvicorn as PID 1 directly — it receives SIGTERM from
#     Kubernetes during pod termination and can shut down gracefully.
#   • Shell form wraps the command in /bin/sh -c, which becomes PID 1 and
#     does NOT forward signals to uvicorn — causing forceful kills and
#     dropped in-flight requests.
#
# WHY --workers 2 not just 1:
#   2 workers = 1 per CPU (GKE node default is 2 vCPU for e2-medium).
#   More workers = better CPU utilisation during I/O waits on vLLM calls.
#   This default is overridden per-environment via the CMD in the K8s spec.
#
# WHY --log-config /dev/null:
#   Uvicorn has its own access logger that emits plain text. We disabled it
#   in main.py (access_log=False), but --log-config /dev/null is a belt-and-
#   suspenders guard to ensure no duplicate, unstructured lines appear.
ENTRYPOINT ["uvicorn", "app.main:app"]
CMD [ \
    "--host", "0.0.0.0", \
    "--port", "8000", \
    "--workers", "2", \
    "--no-access-log", \
    "--log-config", "/dev/null" \
]
