

resource "google_container_cluster" "primary" {
  provider = google

  name                = var.cluster_name
  project             = var.project_id
  location            = var.region # Regional cluster — control plane spans 3 zones for HA
  deletion_protection = false

  # ── Node Locations ────────────────────────────────────────────────────────
  
  node_locations = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]

  # ── Bootstrap: remove the default node pool ───────────────────────────────
  
  remove_default_node_pool = true
  initial_node_count       = 1

  # ── Bootstrap node config ─────────────────────────────────────────────────
  
  node_config {
    machine_type    = "e2-standard-4"
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    service_account = google_service_account.gke_node_sa.email
  }

  # ── Networking ────────────────────────────────────────────────────────────
  network    = google_compute_network.vpc.self_link
  subnetwork = google_compute_subnetwork.gke_subnet.self_link

  # VPC-native (alias IP) networking
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range" 
    services_secondary_range_name = "services-range"
  }

  # ── Private Cluster ──────────────────────────────────────

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false 
   
    master_ipv4_cidr_block = "172.16.0.0/28"
  }

  
  
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # ── Workload Identity ─────────────────────────────────────────────────────
  
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # ── Addons ────────────────────────────────────────────────────────────────
  addons_config {
    # HTTP load balancing addon — required for GKE Ingress to provision GCP LBs
    http_load_balancing {
      disabled = false
    }

    # HPA — required for Horizontal Pod Autoscaler resources in k8s/
    horizontal_pod_autoscaling {
      disabled = false
    }

    # GCS Fuse CSI Driver — required for the model-pvc PersistentVolume

    gcs_fuse_csi_driver_config {
      enabled = true
    }

    # Persistent Disk CSI Driver — enabled for standard PVC support
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    # GKE Backup for GKE — disabled (not needed for stateless workloads)
    gke_backup_agent_config {
      enabled = false
    }
  }

  # ── Release Channel ───────────────────────────────────────────────────────

  release_channel {
    channel = "REGULAR"
  }

  # ── Maintenance Window ────────────────────────────────────────────────────

  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T02:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU" # Weekends only
    }
  }

  # ── Shielded Nodes ────────────────────────────────────────────────────────
  
  enable_shielded_nodes = true

  # ── Intra-node Visibility ─────────────────────────────────────────────────
  
  enable_intranode_visibility = true

  # ── Logging & Monitoring ──────────────────────────────────────────────────
 
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER", "STORAGE", "HPA", "POD", "DAEMONSET", "DEPLOYMENT", "STATEFULSET"]

    # Managed Prometheus — scrapes pods automatically, no Prometheus deployment needed
    managed_prometheus {
      enabled = true
    }
  }

  # ── Labels ────────────────────────────────────────────────────────────────
  resource_labels = local.labels

  # ── Lifecycle ─────────────────────────────────────────────────────────────
 
  lifecycle {
    ignore_changes = [
      # GKE auto-updates the master version — ignore to avoid plan drift
      min_master_version,
      node_config,
    ]
  }

  depends_on = [
    google_compute_subnetwork.gke_subnet,
    google_service_account.gke_node_sa,
  ]
}

# ── System Node Pool ──────────────────────────────────────────────────────────


resource "google_container_node_pool" "system_pool" {
  provider = google

  name     = local.system_node_pool_name
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.primary.name

  # ── Node Locations ────────────────────────────────────────────────────────
 
  node_locations = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]

  # ── Auto-scaling ──────────────────────────────────────────────────────────
  autoscaling {
    min_node_count  = var.system_node_min_count 
    max_node_count  = var.system_node_max_count 
    location_policy = "BALANCED"                
  }

  initial_node_count = var.system_node_initial_count

  # ── Management ────────────────────────────────────────────────────────────
  management {
    auto_repair  = true # GKE automatically repairs broken nodes
    auto_upgrade = true # GKE automatically upgrades node version within release channel
  }

  # ── Upgrade Settings ──────────────────────────────────────────────────────
  upgrade_settings {
    max_surge       = 1 # One extra node during upgrades (brief cost spike)
    max_unavailable = 0 # Never remove a node before replacement is ready (HA)
    strategy        = "SURGE"
  }

  node_config {
    machine_type = var.system_node_machine_type # e2-standard-4: 4vCPU, 16GB RAM

    # Use the minimal node SA (not the default Compute SA)
    service_account = google_service_account.gke_node_sa.email

    oauth_scopes = [

      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # ── Disk Configuration ────────────────────────────────────────────────
    disk_size_gb = 100           
    disk_type    = "pd-balanced" 

    # ── OS Image ─────────────────────────────────────────────────────────
  
    image_type = "COS_CONTAINERD"

    # ── Workload Identity on Nodes ────────────────────────────────────────
    workload_metadata_config {

      mode = "GKE_METADATA"
    }

    # ── Shielded Instance Config ─────────────────────────────────────────
    shielded_instance_config {
      enable_secure_boot          = true # Blocks unauthorized kernel/bootloader changes
      enable_integrity_monitoring = true # Detects runtime changes to boot sequence
    }

    # ── Labels ────────────────────────────────────────────────────────────
    labels = merge(local.labels, {
      node-pool = "system"
    })

    # ── Resource Labels (for billing breakdown) ───────────────────────────
    resource_labels = merge(local.labels, {
      node-pool = "system"
    })

    
  }

  lifecycle {
    ignore_changes = [
      
      version,
    ]
  }

  depends_on = [google_container_cluster.primary]
}
