
resource "google_artifact_registry_repository" "docker_repo" {
  provider = google

  project       = var.project_id
  location      = var.region
  repository_id = var.registry_name
  format        = "DOCKER"
  description   = "Docker repository for Mistral Gateway FastAPI container images"

  labels = local.labels

  
  cleanup_policy_dry_run = false # Set to true to preview deletions before enabling

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days — delete untagged images older than 7 days
    }
  }

  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"

    most_recent_versions {
      keep_count = 20 # Always retain the 20 most recently pushed tagged images
    }
  }
}
