



ARG PYTHON_VERSION=3.12
ARG APP_VERSION=0.1.0



FROM python:${PYTHON_VERSION}-slim AS builder


ARG APP_VERSION

# ── Build-time metadata label ─────────────────────────────────────────────────

LABEL org.opencontainers.image.title="mistral-inference-gateway" \
    org.opencontainers.image.description="FastAPI gateway for Mistral-7B-Instruct-v0.3 on GKE" \
    org.opencontainers.image.version="${APP_VERSION}" \
    org.opencontainers.image.source="https://github.com/your-org/mistral-gke"

# ── System build dependencies ─────────────────────────────────────────────────
#
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    libffi-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Create an isolated virtualenv ─────────────────────────────────────────────

ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv ${VIRTUAL_ENV}

# ── Activate the venv for all subsequent RUN commands ─────────────────────────

ENV PATH="${VIRTUAL_ENV}/bin:${PATH}" \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# ── Upgrade pip inside the venv ───────────────────────────────────────────────

RUN pip install --upgrade pip==25.1.1

# ── Copy requirements first — exploit Docker layer cache ─────────────────────

COPY requirements.txt .

# ── Install Python dependencies ───────────────────────────────────────────────

RUN pip install -r requirements.txt



# STAGE 2: runtime

FROM python:${PYTHON_VERSION}-slim AS runtime

# ── Redeclare ARGs in scope for this stage ────────────────────────────────────
ARG APP_VERSION

# ── Runtime metadata labels ───────────────────────────────────────────────────
LABEL org.opencontainers.image.title="mistral-inference-gateway" \
    org.opencontainers.image.description="FastAPI gateway for Mistral-7B-Instruct-v0.3 on GKE" \
    org.opencontainers.image.version="${APP_VERSION}"

# ── Runtime system dependencies ───────────────────────────────────────────────

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    libffi8 \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user ─────────────────────────────────────────────────────────────

RUN groupadd --gid 1001 appgroup \
    && useradd \
    --uid 1001 \
    --gid appgroup \
    --no-create-home \
    --shell /sbin/nologin \
    appuser

# ── Copy the pre-built virtualenv from builder ────────────────────────────────

COPY --from=builder /opt/venv /opt/venv

# ── Activate the venv in the runtime environment ──────────────────────────────

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}" \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ── Application working directory ─────────────────────────────────────────────

WORKDIR /app

# ── Copy application source ───────────────────────────────────────────────────

COPY --chown=appuser:appgroup app/ ./app/

# ── Switch to non-root user ───────────────────────────────────────────────────

USER appuser

# ── Runtime environment variables ─────────────────────────────────────────────

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_ENV=production \
    APP_VERSION=${APP_VERSION} \
    HOST=0.0.0.0 \
    PORT=8000 \
    WORKERS=2 \
    LOG_LEVEL=INFO

# ── Expose the application port ───────────────────────────────────────────────

EXPOSE 8000

# ── Health check ─────────────────────────────────────────────────────────────

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
    || exit 1

# ── Entrypoint and command ────────────────────────────────────────────────────


ENTRYPOINT ["uvicorn", "app.main:app"]
CMD [ \
    "--host", "0.0.0.0", \
    "--port", "8000", \
    "--workers", "2", \
    "--no-access-log" \
    ]
