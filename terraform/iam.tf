# =============================================================================
# terraform/iam.tf
#
# RESOURCES CREATED:
#   1. google_service_account   × 4 — GKE node SA + 3 workload GSAs
#   2. google_project_iam_member × N — IAM role bindings for each SA
#   3. google_storage_bucket_iam_member × 2 — GCS bucket-scoped bindings
#
# PRINCIPLE OF LEAST PRIVILEGE:
#   Each service account receives ONLY the roles required for its function.
#   No SA has Project Owner or Editor — those roles grant access to everything.
#
# SERVICE ACCOUNT MAP:
#   ┌──────────────────────┬─────────────────────────────────────────────────┐
#   │ GCP Service Account  │ Roles                                           │
#   ├──────────────────────┼─────────────────────────────────────────────────┤
#   │ gke-node-sa          │ roles/logging.logWriter                         │
#   │ (GKE node pool SA)   │ roles/monitoring.metricWriter                   │
#   │                      │ roles/monitoring.viewer                         │
#   │                      │ roles/stackdriver.resourceMetadata.writer       │
#   │                      │ roles/artifactregistry.reader (pull images)     │
#   ├──────────────────────┼─────────────────────────────────────────────────┤
#   │ fastapi-gsa          │ roles/logging.logWriter                         │
#   │ (K8s: fastapi-sa)    │ roles/cloudtrace.agent                          │
#   ├──────────────────────┼─────────────────────────────────────────────────┤
#   │ vllm-gsa             │ roles/logging.logWriter                         │
#   │ (K8s: vllm-sa)       │ roles/cloudtrace.agent                          │
#   │                      │ roles/storage.objectViewer (bucket-scoped)      │
#   ├──────────────────────┼─────────────────────────────────────────────────┤
#   │ model-download-gsa   │ roles/storage.objectAdmin (bucket-scoped)       │
#   │ (K8s: model-dl-sa)   │ roles/storage.legacyBucketReader                │
#   └──────────────────────┴─────────────────────────────────────────────────┘
#
# WHY BUCKET-SCOPED BINDINGS FOR GCS?
#   Project-level `roles/storage.objectViewer` would give access to ALL GCS
#   buckets in the project — including Terraform state buckets, logs buckets, etc.
#   Bucket-scoped bindings (google_storage_bucket_iam_member) restrict access
#   to ONLY the model bucket. This is critical security isolation.
#
# NOTE ON WORKLOAD IDENTITY BINDINGS:
#   The IAM bindings that allow Kubernetes SAs to IMPERSONATE these GCP SAs are
#   in workload_identity.tf (not here). Separating them makes each file's purpose
#   clear: iam.tf = what the GSA can do, workload_identity.tf = who can be the GSA.
# =============================================================================

# ── 1. GKE Node Service Account ───────────────────────────────────────────────
# GKE nodes need their own SA (not the default Compute SA) because:
#   • The default Compute SA has Editor role — way too permissive
#   • This minimal SA can only write logs/metrics and pull images from AR
#   • If a node is compromised, the blast radius is contained
#
# IMPORTANT: Set this SA in gke.tf's node_config.service_account field.

resource "google_service_account" "gke_node_sa" {
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account — Mistral Cluster"
  description  = "Minimal SA for GKE nodes: log/metric write + AR image pull."
  project      = var.project_id
}

# Nodes need to write logs to Cloud Logging (kubelet, container logs)
resource "google_project_iam_member" "node_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Nodes need to write metrics to Cloud Monitoring (HPA, dashboards)
resource "google_project_iam_member" "node_sa_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Nodes need to view metrics for kube-state-metrics and GKE monitoring agent
resource "google_project_iam_member" "node_sa_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Required for GKE's managed Prometheus / Cloud Monarch metadata
resource "google_project_iam_member" "node_sa_metadata_writer" {
  project = var.project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Nodes pull Docker images from Artifact Registry for all pods
resource "google_project_iam_member" "node_sa_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# ── 2. FastAPI GSA ────────────────────────────────────────────────────────────
# Mapped to k8s/fastapi/03-serviceaccount.yaml (fastapi-sa in mistral-gateway namespace)
# via Workload Identity (see workload_identity.tf).
#
# FastAPI pods need:
#   • Log writer: structured JSON logs → Cloud Logging
#   • Trace agent: distributed tracing → Cloud Trace
# FastAPI pods do NOT need GCS access (they call vLLM, not GCS directly).

resource "google_service_account" "fastapi_gsa" {
  account_id   = "fastapi-gsa"
  display_name = "FastAPI Workload Identity GSA"
  description  = "GCP SA for FastAPI pods: Cloud Logging and Cloud Trace write."
  project      = var.project_id
}

resource "google_project_iam_member" "fastapi_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.fastapi_gsa.email}"
}

resource "google_project_iam_member" "fastapi_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.fastapi_gsa.email}"
}

# ── 3. vLLM GSA ───────────────────────────────────────────────────────────────
# Mapped to k8s/vllm/00-serviceaccount.yaml (vllm-sa in mistral-gateway namespace).
#
# vLLM pods need:
#   • Log writer: vLLM inference logs → Cloud Logging
#   • Trace agent: inference latency tracing → Cloud Trace
#   • GCS objectViewer: READ model weights from the model bucket via GCS Fuse CSI
#     (see k8s/model-provisioning/02-persistentvolume.yaml)
#
# WHY BUCKET-SCOPED objectViewer and not project-level?
#   vLLM only needs to read the model bucket — not all GCS buckets.
#   Bucket-scoped IAM limits blast radius if vLLM is compromised.

resource "google_service_account" "vllm_gsa" {
  account_id   = "vllm-gsa"
  display_name = "vLLM Workload Identity GSA"
  description  = "GCP SA for vLLM pods: Cloud Logging, Cloud Trace, GCS model read."
  project      = var.project_id
}

resource "google_project_iam_member" "vllm_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vllm_gsa.email}"
}

resource "google_project_iam_member" "vllm_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.vllm_gsa.email}"
}

# GCS objectViewer scoped to the model bucket only (set after bucket is created)
resource "google_storage_bucket_iam_member" "vllm_model_reader" {
  bucket = google_storage_bucket.model_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.vllm_gsa.email}"
}

# ── 4. Model Download GSA ─────────────────────────────────────────────────────
# Mapped to k8s/model-provisioning/00-serviceaccount.yaml
# (model-download-sa in mistral-gateway namespace).
#
# The download Job needs:
#   • objectAdmin: create and overwrite objects in the model bucket
#     (gcloud storage cp / huggingface-cli download → GCS)
#   • legacyBucketReader: list bucket contents to verify upload completeness
#
# WHY SEPARATE FROM vllm-gsa?
#   vLLM should NEVER have write access to its own model files.
#   If a vLLM pod is compromised, the attacker cannot overwrite model weights
#   or inject malicious model files. The download SA is active only during
#   the provisioning Job and poses zero risk to serving.

resource "google_service_account" "model_download_gsa" {
  account_id   = "model-download-gsa"
  display_name = "Model Download Workload Identity GSA"
  description  = "GCP SA for the Mistral model download Job: GCS write to model bucket."
  project      = var.project_id
}

# objectAdmin: read + write + delete objects in the model bucket
resource "google_storage_bucket_iam_member" "model_download_object_admin" {
  bucket = google_storage_bucket.model_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.model_download_gsa.email}"
}

# legacyBucketReader: list bucket contents (required by gsutil and gcloud storage ls)
resource "google_storage_bucket_iam_member" "model_download_bucket_reader" {
  bucket = google_storage_bucket.model_bucket.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.model_download_gsa.email}"
}
