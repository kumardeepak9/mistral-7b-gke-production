

locals {
  # ── Common Labels ───────────────────────────────────────────────────────────
  
  labels = {
    app         = "mistral-gateway"
    environment = var.environment
    team        = var.team
    managed-by  = "terraform"
  }

  # ── GCS Bucket Name ─────────────────────────────────────────────────────────
  
  model_bucket_name = "${var.project_id}-mistral-models"

  # ── Artifact Registry Hostname ───────────────────────────────────────────────

  registry_hostname = "${var.region}-docker.pkg.dev/${var.project_id}/${var.registry_name}"

  # ── Workload Identity Pool ───────────────────────────────────────────────────
  
  workload_identity_pool = "${var.project_id}.svc.id.goog"

  # ── GKE Node Pool Naming ─────────────────────────────────────────────────────

  system_node_pool_name = "${var.cluster_name}-system-pool"
  gpu_node_pool_name    = "${var.cluster_name}-gpu-pool"

  # ── GPU Node Taint ───────────────────────────────────────────────────────────
 
  gpu_taint_key   = "nvidia.com/gpu"
  gpu_taint_value = "present"
}
