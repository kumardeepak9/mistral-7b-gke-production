

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
