

resource "google_storage_bucket" "model_bucket" {
  name          = local.model_bucket_name
  project       = var.project_id
  location      = var.model_bucket_location
  storage_class = var.model_bucket_storage_class
  force_destroy = true

  labels = local.labels

  # ── Access Control ─────────────────────────────────────────

  uniform_bucket_level_access = true


  public_access_prevention = "enforced"

  # ── Versioning ───
  versioning {
    enabled = true
  }

  # ── Soft Delete Policy ───────────────────
  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  # ── Lifecycle Rules ───────────────────────────────────────────────────────

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 3          # Keep only the 3 most recent versions
      with_state         = "ARCHIVED" # Only delete non-current (archived) versions
    }
  }

 
 
}
