# =============================================================================
# terraform/versions.tf
#
# WHY THIS FILE?
#   Terraform requires explicit version constraints to guarantee reproducible
#   infrastructure. Without pinning, `terraform init` might download a newer
#   provider that has breaking API changes, causing silent drift.
#
# REQUIRED PROVIDERS:
#   google         → Primary GCP resources (GKE, VPC, IAM, GCS, AR)
#   google-beta    → Beta resources: GKE Workload Identity Pool, some GKE flags
#                    We import only what we need; the google-beta provider is
#                    aliased alongside google (same credentials, different API endpoint)
#   random         → random_id for globally unique GCS bucket / AR names
#
# REMOTE BACKEND (GCS):
#   WHY remote state?
#     Local tfstate means:
#       • Only one developer can run terraform at a time (no locking)
#       • State is lost if the machine is lost
#       • CI/CD pipelines cannot access state
#     GCS backend:
#       • State stored in a GCS object (versioned bucket)
#       • State locking via GCS object preconditions (prevents concurrent applies)
#       • Audit trail via GCS access logs
#       • State encryption via CMEK or Google-managed keys
#
#   PARTIAL CONFIGURATION:
#     The bucket and prefix are NOT hard-coded here. They are passed via
#     `terraform init -backend-config=...` so this file is project-agnostic.
#     Developers supply:
#       -backend-config="bucket=${PROJECT_ID}-tf-state"
#       -backend-config="prefix=mistral-gateway"
#
# REQUIRED GCLOUD APIS (enable once per project):
#   gcloud services enable \
#     container.googleapis.com \
#     artifactregistry.googleapis.com \
#     iam.googleapis.com \
#     cloudresourcemanager.googleapis.com \
#     compute.googleapis.com \
#     storage.googleapis.com \
#     logging.googleapis.com \
#     cloudtrace.googleapis.com \
#     --project=${PROJECT_ID}
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ── Remote State Backend ──────────────────────────────────────────────────
  # Bucket and prefix are supplied at `terraform init` time via -backend-config.
  # This keeps the file project-agnostic and safe to commit.
  #
  # Create the backend bucket BEFORE running terraform init:
  #   gcloud storage buckets create gs://${PROJECT_ID}-tf-state \
  #     --location=${REGION} \
  #     --uniform-bucket-level-access \
  #     --versioning \
  #     --project=${PROJECT_ID}
  backend "gcs" {
    # bucket = passed via -backend-config at init time
    # prefix = passed via -backend-config at init time
  }
}

# ── Provider Configuration ────────────────────────────────────────────────────
# WHY configure providers here and not in gke.tf / iam.tf?
#   Centralising provider config means changing credentials or project ID
#   is done in one place. All resource files inherit these settings.
#
# Application Default Credentials (ADC):
#   Locally:   `gcloud auth application-default login`
#   In CI/CD:  GOOGLE_APPLICATION_CREDENTIALS env var pointing to SA key JSON
#              (better: Workload Identity Federation for keyless CI auth)
#
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
