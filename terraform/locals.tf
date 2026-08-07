# =============================================================================
# terraform/locals.tf
#
# WHY LOCALS?
#   locals.tf centralises expressions derived from input variables so that:
#   • Complex expressions (e.g. bucket name, WI pool URI) are computed ONCE.
#     If the naming convention changes, update one local — not 5 resource blocks.
#   • Resource files stay readable: `local.labels` vs repeating 4 label lines.
#   • Derived names stay consistent — no typo divergence between files.
#
# LOCALS vs VARIABLES:
#   • variable  = external input (user supplies)
#   • local     = internal computed value (Terraform derives from variables)
#   Never declare a local for something a variable can express directly.
# =============================================================================

locals {
  # ── Common Labels ───────────────────────────────────────────────────────────
  # Applied to every resource so Cloud Billing can break costs down by team,
  # environment, and component. GCP labels must be lowercase, no spaces.
  #
  # Usage: labels = local.labels
  labels = {
    app         = "mistral-gateway"
    environment = var.environment
    team        = var.team
    managed-by  = "terraform"
  }

  # ── GCS Bucket Name ─────────────────────────────────────────────────────────
  # WHY include project_id?
  #   GCS bucket names are globally unique across ALL GCP projects. Without a
  #   project-scoped prefix, names like "mistral-models" will almost certainly
  #   be taken. ${project_id} guarantees uniqueness for your project.
  #
  # This name must match the bucket referenced in:
  #   k8s/model-provisioning/02-persistentvolume.yaml (GCS Fuse volumeHandle)
  #   k8s/model-provisioning/00-serviceaccount.yaml   (gcloud storage IAM commands)
  model_bucket_name = "${var.project_id}-mistral-models"

  # ── Artifact Registry Hostname ───────────────────────────────────────────────
  # Full Docker push/pull URL. Used in outputs and can be used in CI/CD pipelines.
  # Format: {region}-docker.pkg.dev/{project}/{repository}
  #
  # Example: us-central1-docker.pkg.dev/my-project/mistral-registry
  registry_hostname = "${var.region}-docker.pkg.dev/${var.project_id}/${var.registry_name}"

  # ── Workload Identity Pool ───────────────────────────────────────────────────
  # GKE Workload Identity maps a Kubernetes ServiceAccount to a GCP Service Account
  # using the project's Workload Identity Pool:
  #   Pool URI format: {project_id}.svc.id.goog
  #
  # WHY is this important?
  #   The IAM member string for Workload Identity bindings is:
  #     serviceAccount:{pool}[{namespace}/{k8s-sa-name}]
  #   We pre-compute the pool here so workload_identity.tf stays readable.
  workload_identity_pool = "${var.project_id}.svc.id.goog"

  # ── GKE Node Pool Naming ─────────────────────────────────────────────────────
  # Consistent naming convention: {cluster_name}-{pool_type}-pool
  system_node_pool_name = "${var.cluster_name}-system-pool"
  gpu_node_pool_name    = "${var.cluster_name}-gpu-pool"

  # ── GPU Node Taint ───────────────────────────────────────────────────────────
  # GKE automatically applies nvidia.com/gpu=present:NoSchedule to GPU nodes
  # when nvidia_gpu_driver_installation_config is set. This taint prevents
  # non-GPU pods from being scheduled on expensive GPU nodes.
  # The vLLM Deployment (k8s/vllm/01-deployment.yaml) has a matching toleration.
  gpu_taint_key   = "nvidia.com/gpu"
  gpu_taint_value = "present"
}
