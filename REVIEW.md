# Repository Review Report

Date: 2026-08-07

## 1) Current project structure

- App code: [app/](/Users/deepak/Desktop/K8s project/app)
  - Entry/config/logging: [main.py](</Users/deepak/Desktop/K8s project/app/main.py>), [config.py](</Users/deepak/Desktop/K8s project/app/config.py>), [logging_config.py](</Users/deepak/Desktop/K8s project/app/logging_config.py>)
  - Middleware: [middleware/logging.py](</Users/deepak/Desktop/K8s project/app/middleware/logging.py>)
  - Routers: [routers/health.py](</Users/deepak/Desktop/K8s project/app/routers/health.py>), [routers/inference.py](</Users/deepak/Desktop/K8s project/app/routers/inference.py>)
- Container/runtime:
  - [Dockerfile](</Users/deepak/Desktop/K8s project/Dockerfile>)
  - [docker-compose.yml](</Users/deepak/Desktop/K8s project/docker-compose.yml>)
  - [requirements.txt](</Users/deepak/Desktop/K8s project/requirements.txt>)
  - [.env.example](</Users/deepak/Desktop/K8s project/.env.example>)
- Kubernetes:
  - FastAPI: [k8s/fastapi/](/Users/deepak/Desktop/K8s project/k8s/fastapi)
  - vLLM: [k8s/vllm/](/Users/deepak/Desktop/K8s project/k8s/vllm)
  - Networking: [k8s/networking/](/Users/deepak/Desktop/K8s project/k8s/networking)
  - Model provisioning: [k8s/model-provisioning/](/Users/deepak/Desktop/K8s project/k8s/model-provisioning)
- CI/CD:
  - [ci.yaml](</Users/deepak/Desktop/K8s project/.github/workflows/ci.yaml>)
  - [cd.yaml](</Users/deepak/Desktop/K8s project/.github/workflows/cd.yaml>)

---

## 2) Missing files

- No repository README (no `README*` found).
- No tests directory/files (`tests/` missing while CI references tests).
- No Terraform files (`*.tf` and `*.tfvars*` missing) despite repeated Terraform/GCP provisioning references in manifests/comments.
- No Kubernetes environment overlays (`kustomization.yaml`, Helm chart, or env-specific overlays).

---

## 3) Missing configurations

- No lint/format config files (`pyproject.toml`, `ruff.toml`, `black` config), so CI uses tool defaults only.
- No Python test config (`pytest.ini`/`pyproject` pytest section).
- No dependency lockfile for Python reproducibility (e.g., `requirements-lock.txt` / `pip-tools` output).
- No explicit NetworkPolicy manifests in [k8s/](/Users/deepak/Desktop/K8s project/k8s) to enforce FastAPI→vLLM-only traffic.
- No HPA/VPA manifests for [fastapi deployment](</Users/deepak/Desktop/K8s project/k8s/fastapi/04-deployment.yaml>) or [vllm deployment](</Users/deepak/Desktop/K8s project/k8s/vllm/01-deployment.yaml>).

---

## 4) Broken imports

- No clear internal broken imports found in [app/](/Users/deepak/Desktop/K8s project/app).
- External import risk: environment currently lacks Python runtime tooling; runtime import correctness is not validated here by execution.

---

## 5) Missing environment variables

- App-level variables in [config.py](</Users/deepak/Desktop/K8s project/app/config.py>) are covered by [.env.example](</Users/deepak/Desktop/K8s project/.env.example>).
- Gaps:
  - `GATEWAY_API_KEY` and `VLLM_API_KEY` exist in [k8s secret](</Users/deepak/Desktop/K8s project/k8s/fastapi/02-secret.yaml>) but are not documented in [.env.example](</Users/deepak/Desktop/K8s project/.env.example>) and not enforced in app code.
  - Required CI/CD secrets are referenced in [cd.yaml](</Users/deepak/Desktop/K8s project/.github/workflows/cd.yaml>) but there is no single source-of-truth env contract file for operators.

---

## 6) Kubernetes issues

- Placeholder values block production use by default:
  - image path placeholders in [fastapi deployment](</Users/deepak/Desktop/K8s project/k8s/fastapi/04-deployment.yaml>)
  - domain placeholders in [managed cert](</Users/deepak/Desktop/K8s project/k8s/networking/00-managed-certificate.yaml>) and [ingress](</Users/deepak/Desktop/K8s project/k8s/networking/03-ingress.yaml>)
  - GCP SA placeholders in service accounts under [k8s/](/Users/deepak/Desktop/K8s project/k8s)
- [fastapi deployment](</Users/deepak/Desktop/K8s project/k8s/fastapi/04-deployment.yaml>) exposes Prometheus scrape annotations for `/metrics`, but app has no `/metrics` endpoint.
- [model-downloader job](</Users/deepak/Desktop/K8s project/k8s/model-provisioning/04-job.yaml>) sets non-root UID and then runs `apt-get`; this is likely to fail due to missing root privileges.
- No NetworkPolicy resources for east-west traffic hardening.
- Readiness in [health router](</Users/deepak/Desktop/K8s project/app/routers/health.py>) does not actually verify vLLM reachability yet.

---

## 7) Terraform issues

- Terraform is currently absent from the repository.
- This is a major gap because multiple resources are described as Terraform-managed (bucket/project/identity/policies), but no IaC stateful source exists.
- Risks: manual drift, unreproducible infrastructure, weak auditability.

---

## 8) FastAPI issues

- Inference endpoint is still a stub in [inference router](</Users/deepak/Desktop/K8s project/app/routers/inference.py>) and does not proxy to vLLM yet.
- No API-key enforcement in application layer despite gateway secret presence.
- Readiness endpoint catches broad exceptions and does not include downstream dependency checks.
- CORS is effectively disabled in production (`allow_origins=[]`) in [main.py](</Users/deepak/Desktop/K8s project/app/main.py>), which may break browser clients unless intentional.
- OpenAPI-aligned `/v1/models` endpoint is documented in [API gateway spec](</Users/deepak/Desktop/K8s project/k8s/networking/04-api-gateway-openapi.yaml>) but not implemented in app routes.

---

## 9) Docker issues

- [docker-compose.yml](</Users/deepak/Desktop/K8s project/docker-compose.yml>) uses `deploy.resources`, which is ignored by normal Docker Compose (non-Swarm), giving false local resource-limit assumptions.
- OCI source label in [Dockerfile](</Users/deepak/Desktop/K8s project/Dockerfile>) still contains placeholder org/repo URL.
- Container healthcheck exists and is valid, but Kubernetes probes already govern production behavior.

---

## 10) GitHub Actions issues

- [CI workflow](</Users/deepak/Desktop/K8s project/.github/workflows/ci.yaml>) can pass with no tests (`tests/` missing), so quality gate is weak.
- CI path filters ignore most Kubernetes manifests; infra regressions can bypass CI.
- [CD workflow](</Users/deepak/Desktop/K8s project/.github/workflows/cd.yaml>) triggers on `k8s/fastapi/**` changes but deploy step only does `kubectl set image`; config/manifest changes are not applied.
- Actions are version-pinned by tags, not commit SHA digests (supply-chain hardening gap).

---

## 11) Security issues

- Placeholder secrets are committed in [k8s/fastapi/02-secret.yaml](</Users/deepak/Desktop/K8s project/k8s/fastapi/02-secret.yaml>) and [k8s/model-provisioning/01-secret.yaml](</Users/deepak/Desktop/K8s project/k8s/model-provisioning/01-secret.yaml>) (not real secrets, but risky pattern).
- No enforced app-layer authentication/authorization in FastAPI for inference endpoints.
- No NetworkPolicies present (lateral movement risk inside namespace).
- Broad exception handling in readiness path can hide root cause and degrade observability quality.

---

## 12) Performance issues

- Inference path is stubbed; end-to-end performance cannot be validated yet.
- No autoscaling manifests (HPA) for traffic spikes.
- Fixed worker count strategy in config may not match runtime CPU topology across environments.
- Missing `/metrics` endpoint prevents proper performance telemetry despite scrape annotations.

---

## 13) Production readiness score

**Score: 54 / 100**

### Scoring rationale
- **Strengths (+):**
  - Strong baseline structure for FastAPI, Docker multi-stage builds, and K8s decomposition.
  - Good probe/security-context intent in manifests.
  - CI/CD pipeline design is thoughtful and documented.
- **Major blockers (-):**
  - Terraform absent.
  - Inference still stubbed.
  - Model provisioning job likely privilege-broken.
  - CD does not apply manifest/config changes.
  - Missing tests and missing runtime observability endpoint (`/metrics`).
  - Placeholder infra/domain/service-account values throughout deployment stack.

### Readiness verdict

Current state is **architecture-ready but not production-ready**.  
Primary blockers are implementation completeness, infra-as-code completeness, and deployment correctness.
