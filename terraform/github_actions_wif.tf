# ── GitHub Actions Workload Identity Federation (WIF) ──────
# This file provisions keyless authentication between GitHub Actions and GCP.

variable "github_repository" {
  description = "GitHub repository formatted as <owner>/<repo> allowed to authenticate via WIF."
  type        = string
  default     = "kumardeepak9/mistral-7b-gke-production"
}

# 1. Workload Identity Pool for GitHub Actions
resource "google_iam_workload_identity_pool" "github_actions" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Workload Identity Pool for GitHub Actions CI/CD"
  disabled                  = false
  project                   = var.project_id
}

# 2. Workload Identity Pool Provider for GitHub Actions OIDC
resource "google_iam_workload_identity_pool_provider" "github_actions" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions-provider"
  display_name                       = "GitHub Actions OIDC Provider"
  description                        = "OIDC Provider for GitHub Actions"
  project                            = var.project_id

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# 3. Dedicated GCP Service Account for GitHub Actions CI/CD
resource "google_service_account" "github_actions_sa" {
  account_id   = "github-actions-sa"
  display_name = "GitHub Actions CI/CD Service Account"
  description  = "Service account for GitHub Actions CI/CD to push to Artifact Registry and deploy to GKE"
  project      = var.project_id
}

# 4. Bind GitHub Repository to the Service Account (Impersonation permission)
resource "google_service_account_iam_member" "github_actions_wif_binding" {
  service_account_id = google_service_account.github_actions_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repository}"
}

# ── IAM Roles for GitHub Actions Service Account ─────────────────────────────

# Permission to push container images to Artifact Registry
resource "google_project_iam_member" "github_actions_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions_sa.email}"
}

# Permission to inspect / describe Artifact Registry repository
resource "google_project_iam_member" "github_actions_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.github_actions_sa.email}"
}

# Permission to deploy workloads to GKE and manage pods/deployments/services
resource "google_project_iam_member" "github_actions_gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_actions_sa.email}"
}

# Permission to get GKE cluster credentials and metadata
resource "google_project_iam_member" "github_actions_gke_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.github_actions_sa.email}"
}
