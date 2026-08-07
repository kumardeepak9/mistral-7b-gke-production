# =============================================================================
# terraform/artifact_registry.tf
#
# RESOURCE CREATED:
#   google_artifact_registry_repository — Docker repository for FastAPI images
#
# WHY ARTIFACT REGISTRY (not Docker Hub or GCR)?
#   Docker Hub:
#     • Rate-limited to 100 pulls/6h (anonymous) or 200 pulls/6h (free account)
#     • Images not in GCP — adds egress latency when pulling inside GKE
#     • No native GCP IAM — credentials must be managed manually
#
#   Container Registry (GCR, legacy):
#     • Deprecated — Google recommends migrating to Artifact Registry
#     • Backed by GCS, not a dedicated service
#     • No repository-level IAM (all images in a project share permissions)
#
#   Artifact Registry:
#     • Native GCP service — pulls from GKE are fast and free (same region)
#     • Per-repository IAM — production and staging can have different access policies
#     • Built-in Artifact Analysis (vulnerability scanning via CVE databases)
#     • Binary Authorization integration — enforce signed image policies
#     • Multi-format: Docker, npm, Maven, Python, Helm — one service for all
#     • CMEK support — encrypt images with customer-managed keys
#     • VPC Service Controls support for compliance environments
#
# VULNERABILITY SCANNING:
#   When push_config.disable_automatic_scanning = false (the default), every
#   new image push triggers an Artifact Analysis scan. Results appear in:
#     gcloud artifacts docker images describe \
#       ${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/${IMAGE}@${DIGEST}
#   Integrate with Binary Authorization to block deployment of critical CVEs.
#
# DOCKER AUTHENTICATION (for CI/CD):
#   GitHub Actions → Artifact Registry (keyless via Workload Identity Federation):
#     gcloud auth configure-docker ${region}-docker.pkg.dev
#   Or with Service Account key:
#     docker login -u _json_key --password-stdin ${region}-docker.pkg.dev
#
# IMAGE NAMING CONVENTION:
#   ${region}-docker.pkg.dev/${project_id}/${registry_name}/fastapi:${git_sha}
#   Example:
#     us-central1-docker.pkg.dev/my-project/mistral-registry/fastapi:abc1234
# =============================================================================

resource "google_artifact_registry_repository" "docker_repo" {
  provider = google

  project       = var.project_id
  location      = var.region
  repository_id = var.registry_name
  format        = "DOCKER"
  description   = "Docker repository for Mistral Gateway FastAPI container images"

  labels = local.labels

  # ── Cleanup Policies ─────────────────────────────────────────────────────────
  # WHY cleanup policies?
  #   Without cleanup, every git push creates a new image tag and the registry
  #   accumulates thousands of old images. AR charges $0.10/GB/month — 100 image
  #   versions × 500 MB each = 50 GB = $5/month just in stale images.
  #
  # KEEP_TAGGED_AND_RECENT: Keep all tagged images AND the last N untagged images.
  # This ensures:
  #   • All git-sha tagged images for rollback reference are retained
  #   • Latest builds are always available
  #   • Dangling untagged layers (from mid-build failures) are cleaned up
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
