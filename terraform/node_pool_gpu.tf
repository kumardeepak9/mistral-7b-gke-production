

resource "google_container_node_pool" "gpu_pool" {
  provider = google

  name     = local.gpu_node_pool_name
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.primary.name

  # Restrict GPU pool to europe-west4-c where NVIDIA L4 capacity is confirmed available
  node_locations = ["europe-west4-c"]

  # ── Auto-scaling ──────────────────────────────────────────────────────────
  
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
  
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
    strategy        = "SURGE"
  }

  node_config {
    machine_type = var.gpu_node_machine_type # g2-standard-12: 12vCPU, 48GB RAM, 1×NVIDIA L4

    
    preemptible = var.gpu_node_preemptible
    spot        = var.gpu_node_spot

    service_account = google_service_account.gke_node_sa.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # ── Disk ─────────────────────────────────────────────────────────────
    
    disk_size_gb = 200
    disk_type    = "pd-balanced"

    # ── GPU Accelerator ───────────────────────────────────────────────────
    
    guest_accelerator {
      type  = var.gpu_type  # "nvidia-l4"
      count = var.gpu_count # 1

      # ── GPU Driver Installation ───────────────────────────────────────
      
      gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT"
      }

      
    }

    # ── OS Image ─────────────────────────────────────────────────────────
    
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
      
      disable-legacy-endpoints = "true"
    }
  }

  depends_on = [
    google_container_cluster.primary,
    google_container_node_pool.system_pool, # System pool must be ready first
  ]

  lifecycle {
    ignore_changes = [
      
      version,
      
      initial_node_count,
    ]

    precondition {
      condition     = !(var.gpu_node_preemptible && var.gpu_node_spot)
      error_message = "gpu_node_preemptible and gpu_node_spot are mutually exclusive. Enable only one."
    }
  }
}
