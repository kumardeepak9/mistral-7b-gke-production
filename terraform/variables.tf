# =============================================================================
# terraform/variables.tf
#
# WHY VARIABLES?
#   Hard-coding project IDs, regions, and names in resource files makes Terraform
#   non-reusable. Variables decouple configuration from code:
#     • Same .tf files deploy to dev, staging, production by changing tfvars
#     • No sensitive data in source control (project IDs stay in CI secrets)
#     • Documentation via `description` — `terraform-docs` auto-generates README
#
# SUPPLYING VALUES (in priority order — highest wins):
#   1. -var flag:           terraform apply -var="project_id=my-project"
#   2. terraform.tfvars:   file (gitignored — for local dev)
#   3. TF_VAR_ env var:     TF_VAR_project_id=my-project terraform apply
#   4. default:             used if no other value provided
#
# REQUIRED VARIABLES (no default — Terraform will prompt or error):
#   • project_id  — must be supplied; no sensible default possible
# =============================================================================

# ── Project ───────────────────────────────────────────────────────────────────

variable "project_id" {
  description = <<-EOT
    GCP project ID in which all resources are created.
    Example: "my-gcp-project-123456"
    Find yours: gcloud projects list
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 6–30 characters, lowercase letters, digits, or hyphens."
  }
}

variable "region" {
  description = <<-EOT
    GCP region for all regional resources (GKE cluster, Artifact Registry, GCS bucket).
    NVIDIA L4 GPUs are available in: us-central1, us-east4, europe-west4, asia-east1.
    Choose the region closest to your users.
  EOT
  type        = string
  default     = "us-central1"
}

# ── Naming ────────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = <<-EOT
    Name of the GKE cluster. Used as a prefix for node pool and related resources.
    Must be unique within the project and region.
  EOT
  type        = string
  default     = "mistral-cluster"
}

variable "network_name" {
  description = "Name of the VPC network to create."
  type        = string
  default     = "mistral-vpc"
}

variable "subnet_name" {
  description = "Name of the VPC subnet for GKE nodes."
  type        = string
  default     = "mistral-subnet"
}

variable "registry_name" {
  description = <<-EOT
    Artifact Registry repository ID. The full hostname will be:
    REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY
  EOT
  type        = string
  default     = "mistral-registry"
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "subnet_cidr" {
  description = <<-EOT
    CIDR range for the GKE node subnet.
    /20 = 4,094 usable IPs — enough for ~400 nodes (each needing ~10 IPs).
    Must not overlap with pod or service CIDRs.
  EOT
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = <<-EOT
    Secondary IP range for GKE pod IPs (VPC-native cluster).
    /16 = 65,536 pod IPs. GKE default allocates /24 per node = 254 pods/node.
    With 10 nodes: 2,540 pods — /16 provides comfortable headroom.
  EOT
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = <<-EOT
    Secondary IP range for GKE Service ClusterIPs.
    /20 = 4,094 service IPs. Kubernetes clusters rarely exceed a few hundred services.
  EOT
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_authorized_networks" {
  description = <<-EOT
    CIDR blocks allowed to access the GKE control plane endpoint.
    Do not use 0.0.0.0/0 in production.
  EOT
  type = list(object({
    display_name = string
    cidr_block   = string
  }))
  default = [
    {
      display_name = "all-for-initial-setup"
      cidr_block   = "0.0.0.0/0"
    }
  ]
}

# ── GKE — System Node Pool ────────────────────────────────────────────────────

variable "system_node_machine_type" {
  description = <<-EOT
    Machine type for the system node pool (runs kube-system pods, kube-dns, etc.).
    e2-standard-4 = 4 vCPU, 16 GB RAM — adequate for GKE system components.
    Do NOT use n1-standard-1 or similar — insufficient RAM causes OOM evictions.
  EOT
  type        = string
  default     = "e2-standard-4"
}

variable "system_node_min_count" {
  description = "Minimum number of system nodes per zone (for auto-scaling)."
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum number of system nodes per zone (for auto-scaling)."
  type        = number
  default     = 3
}

variable "system_node_initial_count" {
  description = <<-EOT
    Initial node count per zone for the system pool before auto-scaling kicks in.
    Keep at 1 to minimise costs on first apply.
  EOT
  type        = number
  default     = 1
}

# ── GKE — GPU Node Pool ───────────────────────────────────────────────────────

variable "gpu_node_machine_type" {
  description = <<-EOT
    Machine type for the GPU node pool.
    g2-standard-12 = 12 vCPU, 48 GB RAM, 1× NVIDIA L4 (24 GB VRAM).
    Mistral-7B FP16 requires ~14 GB VRAM + ~4 GB for KV cache = 18 GB total.
    L4's 24 GB VRAM provides comfortable headroom without needing bfloat16 quantisation.
    See: https://cloud.google.com/compute/docs/gpus#nvidia-l4
  EOT
  type        = string
  default     = "g2-standard-12"
}

variable "gpu_type" {
  description = <<-EOT
    GPU accelerator type to attach to each GPU node.
    nvidia-l4 is the recommended choice for Mistral-7B inference:
    • Cost-effective: ~$0.70/hr spot vs $2.93/hr for A100-40GB
    • 24 GB VRAM fits Mistral-7B FP16 with room for long contexts
    • Lower TDP (72W vs 300W) = cheaper to run at scale
  EOT
  type        = string
  default     = "nvidia-l4"
}

variable "gpu_count" {
  description = "Number of GPUs to attach per node. 1 L4 is sufficient for Mistral-7B."
  type        = number
  default     = 1
}

variable "gpu_node_min_count" {
  description = <<-EOT
    Minimum number of GPU nodes per zone.
    Set to 1 (not 0) in production to avoid cold-start latency when the first
    request arrives after scale-to-zero. Set to 0 in dev to save money overnight.
  EOT
  type        = number
  default     = 1
}

variable "gpu_node_max_count" {
  description = <<-EOT
    Maximum number of GPU nodes per zone.
    3 nodes × 1 L4 = 3 GPU replicas max (matches vllm/01-deployment.yaml HPA target).
    Each node costs ~$0.70/hr spot, so max cost = 3 × $0.70 × 730 ≈ $1,533/month.
  EOT
  type        = number
  default     = 3
}

variable "gpu_node_initial_count" {
  description = "Initial GPU node count per zone before auto-scaling."
  type        = number
  default     = 1
}

variable "gpu_node_preemptible" {
  description = <<-EOT
    Use preemptible GPU nodes (up to 80% cheaper, but can be reclaimed with 30s notice).
    Set true for dev/staging, false for production.
    GKE handles preemption gracefully with pod disruption budgets (vllm/03-pdb.yaml).
  EOT
  type        = bool
  default     = false
}

variable "gpu_node_spot" {
  description = <<-EOT
    Use Spot (Flexible) VM pricing for GPU nodes (~60-70% discount vs on-demand).
    Spot VMs are similar to preemptible but have variable pricing.
    Mutually exclusive with preemptible; prefer spot for new deployments.
  EOT
  type        = bool
  default     = false
}

# ── GCS Bucket ────────────────────────────────────────────────────────────────

variable "model_bucket_location" {
  description = <<-EOT
    Location for the model GCS bucket. Should be in the same region as the GKE
    cluster to minimise GCS Fuse latency and avoid cross-region egress charges.
    Single-region (e.g. "US-CENTRAL1") is cheaper than multi-region ("US").
  EOT
  type        = string
  default     = "US-CENTRAL1"
}

variable "model_bucket_storage_class" {
  description = <<-EOT
    Storage class for model weights:
    • STANDARD   — best latency, highest cost ($0.020/GB/month) — recommended for active serving
    • NEARLINE   — 30-day minimum, $0.010/GB/month — good for infrequently served models
    • COLDLINE   — 90-day minimum, $0.004/GB/month — archival only
  EOT
  type        = string
  default     = "STANDARD"
}

# ── Environment / Labels ──────────────────────────────────────────────────────

variable "environment" {
  description = "Deployment environment. Applied as a label on all resources for cost attribution."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be one of: development, staging, production."
  }
}

variable "team" {
  description = "Team label applied to all resources for cost attribution in Cloud Billing."
  type        = string
  default     = "ml-platform"
}
