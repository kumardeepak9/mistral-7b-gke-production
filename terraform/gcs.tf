# =============================================================================
# terraform/gcs.tf
#
# RESOURCE CREATED:
#   google_storage_bucket — Stores Mistral-7B-Instruct-v0.3 model weights
#
# WHY GCS FOR MODEL WEIGHTS?
#   Options for storing 14 GB of model weights in GKE:
#
#   Option A — Bake into Docker image:
#     • Image size: 14 GB → 10+ min push/pull times
#     • CR/AR storage cost: 14 GB × $0.10 = $1.40/month (per image version)
#     • Cannot share between pods without a re-pull
#     • BAD — wrong tool for large binary assets
#
#   Option B — Persistent Disk (ReadWriteOnce):
#     • Fast reads (NVMe SSD), but only ONE node can mount at a time
#     • Prevents multiple vLLM replicas from reading simultaneously
#     • Disk cost: 100 GB SSD PD = $17/month
#     • Works for single-replica setups only
#
#   Option C — GCS + GCS Fuse CSI (chosen):
#     • Multiple pods (ReadOnlyMany) can mount simultaneously
#     • GCS Fuse memory-caches hot blocks → repeated reads are near-instant
#     • Cost: 30 GB × $0.020 = $0.60/month (STANDARD storage)
#     • Decoupled from Kubernetes — model files persist across cluster rebuilds
#     • Bucket contents managed independently of infrastructure
#
# GCS FUSE CSI INTEGRATION:
#   This bucket is referenced in:
#     k8s/model-provisioning/02-persistentvolume.yaml — volumeHandle is bucket name
#     k8s/model-provisioning/04-job.yaml — Job writes model files here
#     k8s/vllm/01-deployment.yaml — PVC mounts this bucket via GCS Fuse
#
# BUCKET NAME:
#   `local.model_bucket_name` = "${project_id}-mistral-models"
#   GCS bucket names are GLOBALLY unique. Including the project ID prevents
#   naming conflicts with other GCP projects using this same Terraform config.
#
# VERSIONING:
#   Enabled to protect against accidental file deletion or model corruption.
#   If a model file is deleted or overwritten, the previous version is recoverable.
#   Cost: only non-current versions incur storage charges. With a 30-day lifecycle
#   rule (below), stale non-current versions are automatically deleted.
#
# SOFT DELETE:
#   GCS soft delete (default 7 days) retains deleted objects for recovery.
#   Useful during model-download Job failures — aborted uploads are recoverable.
# =============================================================================

resource "google_storage_bucket" "model_bucket" {
  name          = local.model_bucket_name
  project       = var.project_id
  location      = var.model_bucket_location
  storage_class = var.model_bucket_storage_class

  labels = local.labels

  # ── Access Control ────────────────────────────────────────────────────────────
  # Uniform bucket-level access (UBLA):
  #   Disables per-object ACLs and uses IAM exclusively for access control.
  #   WHY UBLA?
  #     • Object ACLs are legacy, inconsistent, and hard to audit
  #     • UBLA guarantees that IAM alone controls who can read/write
  #     • Required for VPC Service Controls (SOC 2 / HIPAA compliance)
  #     • Best practice: https://cloud.google.com/storage/docs/uniform-bucket-level-access
  uniform_bucket_level_access = true

  # Prevent public access — model weights must never be publicly readable.
  # public_access_prevention = "enforced" blocks:
  #   • allUsers and allAuthenticatedUsers IAM members
  #   • Anonymous reads via signed URLs (if no public grant exists)
  public_access_prevention = "enforced"

  # ── Versioning ─────────────────────────────────────────────────────────────
  # Protects against accidental deletion or corruption of model weight files.
  versioning {
    enabled = true
  }

  # ── Soft Delete Policy ─────────────────────────────────────────────────────
  # Retains deleted objects for 7 days before permanent deletion.
  # Allows recovery from accidental gsutil rm or failed uploads.
  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  # ── Lifecycle Rules ───────────────────────────────────────────────────────
  # WHY lifecycle rules?
  #   Without cleanup, old non-current object versions accumulate and incur
  #   ongoing storage charges. Model files are large (14+ GB total) — keeping
  #   10 old versions = 140 GB = $2.80/month for nothing.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 3          # Keep only the 3 most recent versions
      with_state         = "ARCHIVED" # Only delete non-current (archived) versions
    }
  }

  # ── CORS Configuration ────────────────────────────────────────────────────
  # Model weights are binary files, not web assets. CORS is not needed.
  # Omitting cors block means default (no CORS headers) — correct for this bucket.

  # ── Retention Policy ─────────────────────────────────────────────────────
  # Not configured here. Add a retention policy if regulatory compliance
  # (e.g., FINRA, SEC) requires immutable audit artifacts. Model weights
  # need to be updatable, so retention locks are not appropriate.
}
