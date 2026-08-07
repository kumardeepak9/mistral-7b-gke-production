# =============================================================================
# terraform/node_pool_gpu.tf
#
# RESOURCE CREATED:
#   google_container_node_pool — NVIDIA L4 GPU node pool for vLLM inference
#
# WHY A SEPARATE FILE FROM gke.tf?
#   The GPU node pool has completely different:
#     • Machine type: g2-standard-12 vs e2-standard-4
#     • Disk: 200 GB SSD vs 100 GB balanced (GPU driver takes extra space)
#     • Accelerator config: NVIDIA L4 GPU driver + device plugin
#     • Node taint: nvidia.com/gpu=present:NoSchedule
#     • Scaling policy: based on GPU utilisation (vLLM pods)
#     • Cost: ~5-10x more expensive per node
#   A separate file allows:
#     • Independent `terraform plan` targeting only the GPU pool
#     • Clearer git diffs when tuning GPU pool params
#     • Easy deletion: `terraform destroy -target=google_container_node_pool.gpu_pool`
#
# NVIDIA L4 SELECTION RATIONALE (from k8s/vllm/01-deployment.yaml comments):
#   Mistral-7B-Instruct-v0.3 in FP16:
#     • Model weights: ~14 GB VRAM
#     • KV cache (typical): ~4 GB VRAM
#     • Total: ~18 GB VRAM needed
#   NVIDIA L4 provides 24 GB VRAM:
#     • 6 GB headroom for long context windows
#     • No quantisation needed (can serve FP16 natively)
#     • Cost on GKE: ~$0.70/hr spot, ~$1.40/hr on-demand
#   Compared to alternatives:
#     • A100-40GB ($2.93/hr): 2x VRAM, 2x cost — overkill for a single 7B model
#     • T4 (16 GB VRAM): NOT sufficient — 14 GB weights leaves no KV cache room
#     • L4 at g2-standard-12: 12 vCPU, 48 GB RAM — plenty for vLLM tokenisation
#
# NVIDIA DRIVER MANAGEMENT:
#   nvidia_gpu_driver_installation_config:
#     install_gpu_driver = true tells GKE to automatically install and maintain
#     the NVIDIA driver on GPU nodes via a DaemonSet. Without this:
#       • You must manually install drivers via a custom init container
#       • Drivers may not match the CUDA version required by vLLM
#     GKE installs the version recommended for the GPU type (L4 → CUDA 12.x).
#     The NVIDIA device plugin (exposes nvidia.com/gpu resource) is also installed.
#
# NODE TAINT:
#   nvidia.com/gpu=present:NoSchedule
#   This taint means: "only schedule pods here if they tolerate this taint."
#   Without the taint, kube-dns, monitoring agents, and any pod without a
#   nodeSelector could be scheduled on GPU nodes — wasting expensive GPU resources.
#   The vLLM Deployment (k8s/vllm/01-deployment.yaml) has a matching toleration.
#
# SPOT/PREEMPTIBLE:
#   preemptible = true  → legacy preemptible VMs (24h max lifetime, 30s eviction notice)
#   spot = true         → Spot VMs (flexible pricing, same 30s eviction notice, no 24h limit)
#   Both controlled via variables (default: false for production, set true for dev/staging).
#   GKE + PodDisruptionBudget (vllm/03-pdb.yaml) ensures graceful handling of evictions.
# =============================================================================

resource "google_container_node_pool" "gpu_pool" {
  provider = google

  name     = local.gpu_node_pool_name
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.primary.name

  # ── Auto-scaling ──────────────────────────────────────────────────────────
  # GPU nodes scale based on pod scheduling demand (Cluster Autoscaler).
  # HPA (not yet configured) will scale vLLM Deployment replicas based on GPU
  # utilisation — Cluster Autoscaler then adds/removes nodes to satisfy replica count.
  autoscaling {
    min_node_count  = var.gpu_node_min_count # per zone (1 per zone × 3 zones = min 3 GPU nodes total)
    max_node_count  = var.gpu_node_max_count # per zone (3 per zone × 3 zones = max 9 GPU nodes total)
    location_policy = "ANY"                  # ANY: fill one zone first before spreading (cheaper for spot)
  }

  initial_node_count = var.gpu_node_initial_count

  # ── Management ────────────────────────────────────────────────────────────
  management {
    auto_repair  = true # Auto-repair broken GPU nodes (important for spot reclamation)
    auto_upgrade = true # GKE manages NVIDIA driver updates via node pool upgrades
  }

  # ── Upgrade Settings ──────────────────────────────────────────────────────
  # GPU node upgrades are slower (NVIDIA driver installation during provisioning).
  # BLUE_GREEN strategy creates new nodes first, then drains old ones — 
  # avoids GPU starvation during upgrades by keeping old nodes alive longer.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
    strategy        = "SURGE"
  }

  node_config {
    machine_type = var.gpu_node_machine_type # g2-standard-12: 12vCPU, 48GB RAM, 1×NVIDIA L4

    # Preemptible and Spot are mutually exclusive; use spot for new deployments
    preemptible = var.gpu_node_preemptible
    spot        = var.gpu_node_spot

    service_account = google_service_account.gke_node_sa.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # ── Disk ─────────────────────────────────────────────────────────────
    # 200 GB SSD for GPU nodes:
    #   • 100 GB for OS, kubelet, NVIDIA driver (~5 GB), device plugin
    #   • 100 GB for GCS Fuse local cache (hot model weight blocks)
    #   • pd-ssd: faster IOPS than pd-balanced, important for GCS Fuse cache
    disk_size_gb = 200
    disk_type    = "pd-ssd"

    # ── GPU Accelerator ───────────────────────────────────────────────────
    # Attaches 1 NVIDIA L4 GPU to each node.
    # gpu_partition_size: empty = full GPU (no MIG partitioning).
    #   MIG (Multi-Instance GPU) splits an A100/H100 into smaller slices.
    #   L4 supports MIG but Mistral-7B FP16 needs the full 24 GB VRAM.
    guest_accelerator {
      type  = var.gpu_type  # "nvidia-l4"
      count = var.gpu_count # 1

      # ── GPU Driver Installation ───────────────────────────────────────
      # install_gpu_driver = true: GKE DaemonSet auto-installs NVIDIA driver.
      # Without this, pods will schedule but cannot access the GPU (no /dev/nvidia*).
      # GKE installs the correct driver version for the L4 (CUDA 12.x compatible).
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST" # Always install the newest stable driver
      }

      gpu_sharing_config {
        # GPU time-sharing: allows multiple pods to share one GPU.
        # Disabled here — vLLM uses the full L4 for maximum throughput.
        # Enable with max_shared_clients_per_gpu if you add smaller models.
        gpu_sharing_strategy       = "TIME_SHARING"
        max_shared_clients_per_gpu = 1 # 1 = effectively disabled (exclusive access)
      }
    }

    # ── OS Image ─────────────────────────────────────────────────────────
    # COS_CONTAINERD required for GPU nodes (handles NVIDIA driver kernel modules).
    # ubuntu_containerd would also work but has a larger attack surface.
    image_type = "COS_CONTAINERD"

    # ── Workload Identity ─────────────────────────────────────────────────
    workload_metadata_config {
      mode = "GKE_METADATA" # Required for Workload Identity on GPU nodes
    }

    # ── Shielded Instance Config ──────────────────────────────────────────
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # ── Node Taint ────────────────────────────────────────────────────────
    # Prevents non-GPU pods from being scheduled on GPU nodes.
    # The vLLM Deployment has a matching toleration:
    #   tolerations:
    #   - key: "nvidia.com/gpu"
    #     operator: "Exists"
    #     effect: "NoSchedule"
    taint {
      key    = local.gpu_taint_key   # "nvidia.com/gpu"
      value  = local.gpu_taint_value # "present"
      effect = "NO_SCHEDULE"
    }

    # ── Labels ────────────────────────────────────────────────────────────
    labels = merge(local.labels, {
      node-pool        = "gpu"
      accelerator      = var.gpu_type
      gpu-machine-type = var.gpu_node_machine_type
    })

    resource_labels = merge(local.labels, {
      node-pool   = "gpu"
      accelerator = var.gpu_type
    })

    # ── Metadata ──────────────────────────────────────────────────────────
    metadata = {
      # Disable legacy metadata APIs (security hardening)
      disable-legacy-endpoints = "true"
    }
  }

  depends_on = [
    google_container_cluster.primary,
    google_container_node_pool.system_pool, # System pool must be ready first
  ]

  lifecycle {
    ignore_changes = [
      # GKE manages node version within the release channel
      version,
      # Initial node count changes are driven by auto-scaler, not Terraform
      initial_node_count,
    ]

    precondition {
      condition     = !(var.gpu_node_preemptible && var.gpu_node_spot)
      error_message = "gpu_node_preemptible and gpu_node_spot are mutually exclusive. Enable only one."
    }
  }
}
