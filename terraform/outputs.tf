

# ── Project ────────────────────────────────────────────────────────────────────

output "project_id" {
  description = "GCP project ID. Use to replace PROJECT_ID placeholders in k8s/ manifests."
  value       = var.project_id
}

output "region" {
  description = "GCP region for all resources."
  value       = var.region
}

# ── GKE Cluster ────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = <<-EOT
    GKE cluster name. Use with:
      gcloud container clusters get-credentials $(terraform output -raw cluster_name) \
        --region=$(terraform output -raw region) --project=$(terraform output -raw project_id)
  EOT
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE cluster master endpoint (HTTPS). Used by kubectl and CI/CD."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true # Endpoint is not secret but good practice to avoid logging
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate. Required for kubectl kubeconfig."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "Cluster location (regional). Same as var.region for a regional cluster."
  value       = google_container_cluster.primary.location
}

# ── Artifact Registry ──────────────────────────────────────────────────────────

output "registry_hostname" {
  description = <<-EOT
    Full Artifact Registry Docker hostname for image push/pull.
    Use in CI/CD:
      docker build -t $(terraform output -raw registry_hostname)/fastapi:$${GIT_SHA} .
      docker push $(terraform output -raw registry_hostname)/fastapi:$${GIT_SHA}
    Use in Kubernetes:
      image: $(terraform output -raw registry_hostname)/fastapi:$${GIT_SHA}
  EOT
  value       = local.registry_hostname
}

output "registry_id" {
  description = "Artifact Registry repository ID (short name, not full hostname)."
  value       = google_artifact_registry_repository.docker_repo.repository_id
}

# ── GCS Bucket ─────────────────────────────────────────────────────────────────

output "model_bucket_name" {
  description = <<-EOT
    GCS bucket name for Mistral model weights.
    Use in k8s/model-provisioning/02-persistentvolume.yaml as the volumeHandle:
      volumeHandle: $(terraform output -raw model_bucket_name)
    Use in the download Job:
      gcloud storage cp -r . gs://$(terraform output -raw model_bucket_name)/mistral-7b-instruct/
  EOT
  value       = google_storage_bucket.model_bucket.name
}

output "model_bucket_url" {
  description = "GCS bucket URL (gs:// prefix). Use with gsutil and gcloud storage commands."
  value       = "gs://${google_storage_bucket.model_bucket.name}"
}

# ── Service Account Emails ─────────────────────────────────────────────────────


output "gke_node_sa_email" {
  description = "Email of the GKE node service account. Used in node pool config."
  value       = google_service_account.gke_node_sa.email
}

output "fastapi_gsa_email" {
  description = <<-EOT
    Email of the FastAPI GCP Service Account.
    Replace PROJECT_ID in k8s/fastapi/03-serviceaccount.yaml annotation:
      iam.gke.io/gcp-service-account: $(terraform output -raw fastapi_gsa_email)
  EOT
  value       = google_service_account.fastapi_gsa.email
}

output "vllm_gsa_email" {
  description = <<-EOT
    Email of the vLLM GCP Service Account.
    Replace PROJECT_ID in k8s/vllm/00-serviceaccount.yaml annotation:
      iam.gke.io/gcp-service-account: $(terraform output -raw vllm_gsa_email)
  EOT
  value       = google_service_account.vllm_gsa.email
}

output "model_download_gsa_email" {
  description = <<-EOT
    Email of the model download Job GCP Service Account.
    Replace PROJECT_ID in k8s/model-provisioning/00-serviceaccount.yaml annotation:
      iam.gke.io/gcp-service-account: $(terraform output -raw model_download_gsa_email)
  EOT
  value       = google_service_account.model_download_gsa.email
}

# ── Networking ─────────────────────────────────────────────────────────────────

output "vpc_name" {
  description = "VPC network name. Use when creating additional resources in the same VPC."
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "GKE node subnet name."
  value       = google_compute_subnetwork.gke_subnet.name
}

output "workload_identity_pool" {
  description = <<-EOT
    Workload Identity Pool URI: PROJECT_ID.svc.id.goog
    Used to construct IAM member strings for additional Workload Identity bindings:
      serviceAccount:$(terraform output -raw workload_identity_pool)[namespace/sa-name]
  EOT
  value       = local.workload_identity_pool
}

# ── GitHub Actions Workload Identity Federation ─────────────────────────────

output "github_actions_workload_identity_provider" {
  description = "Workload Identity Provider resource name for GitHub Actions (use as GCP_WORKLOAD_IDENTITY_PROVIDER secret)."
  value       = google_iam_workload_identity_pool_provider.github_actions.name
}

output "github_actions_service_account" {
  description = "GCP Service Account email for GitHub Actions CI/CD (use as GCP_SERVICE_ACCOUNT secret)."
  value       = google_service_account.github_actions_sa.email
}


# ── Post-Apply Instructions ────────────────────────────────────────────────────

output "next_steps" {
  description = "Instructions to run after terraform apply completes."
  value       = <<-EOT

    ╔══════════════════════════════════════════════════════════════════╗
    ║              TERRAFORM APPLY COMPLETE — NEXT STEPS              ║
    ╠══════════════════════════════════════════════════════════════════╣
    ║                                                                  ║
    ║  1. Configure kubectl:                                           ║
    ║     gcloud container clusters get-credentials \                  ║
    ║       ${google_container_cluster.primary.name} \
    ║       --region=${var.region} \                                   ║
    ║       --project=${var.project_id}                                ║
    ║                                                                  ║
    ║  2. Update k8s/ ServiceAccount annotations (replace PROJECT_ID):║
    ║     • k8s/fastapi/03-serviceaccount.yaml                         ║
    ║       → ${google_service_account.fastapi_gsa.email}
    ║     • k8s/vllm/00-serviceaccount.yaml                            ║
    ║       → ${google_service_account.vllm_gsa.email}
    ║     • k8s/model-provisioning/00-serviceaccount.yaml              ║
    ║       → ${google_service_account.model_download_gsa.email}
    ║                                                                  ║
    ║  3. Update k8s/model-provisioning/02-persistentvolume.yaml:      ║
    ║     volumeHandle: ${google_storage_bucket.model_bucket.name}
    ║                                                                  ║
    ║  4. Apply Kubernetes manifests (in order):                       ║
    ║     kubectl apply -f k8s/fastapi/00-namespace.yaml               ║
    ║     kubectl apply -f k8s/fastapi/                                ║
    ║     kubectl apply -f k8s/vllm/                                   ║
    ║     kubectl apply -f k8s/model-provisioning/                     ║
    ║     kubectl apply -f k8s/networking/                             ║
    ║                                                                  ║
    ║  5. Reserve static IP for Ingress:                               ║
    ║     gcloud compute addresses create mistral-gateway-ip \         ║
    ║       --global --project=${var.project_id}                       ║
    ║                                                                  ║
    ╚══════════════════════════════════════════════════════════════════╝
  EOT
}
