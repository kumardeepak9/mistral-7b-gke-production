# =============================================================================
# terraform/gke.tf
#
# RESOURCES CREATED:
#   1. google_container_cluster    — GKE Standard cluster (control plane + config)
#   2. google_container_node_pool  — System node pool (e2-standard-4, no GPU)
#
# WHY GKE STANDARD (not Autopilot)?
#   GKE Autopilot:
#     • Google manages nodes, scaling, and OS patching automatically
#     • Billing by pod resource requests (not node uptime)
#     • DOES NOT support:
#         - Custom GPU taint/toleration (nvidia.com/gpu=present:NoSchedule)
#         - nvidia_gpu_driver_installation_config (needed for L4 driver management)
#         - GCS Fuse CSI Driver (required for model-pvc in vllm/01-deployment.yaml)
#         - Host-level security contexts used in vllm/01-deployment.yaml
#
#   GKE Standard:
#     • Full node control — machine types, taints, node images, disk sizes
#     • All GKE addons supported (GCS Fuse CSI, GPU driver, etc.)
#     • Required for NVIDIA L4 GPU workloads with custom driver management
#     • Node auto-scaling still works (Cluster Autoscaler)
#     • Cost: billed by node uptime regardless of pod usage
#
# REMOVE DEFAULT NODE POOL:
#   When creating a Standard cluster, GKE requires at least one node pool.
#   We create a minimal "default" pool and immediately remove it, replacing it
#   with our custom system pool (this file) and GPU pool (node_pool_gpu.tf).
#   WHY? Terraform cannot rename the initial_node_count pool — it must be
#   destroyed and replaced with properly configured pools.
#   remove_default_node_pool = true + initial_node_count = 1 is the standard pattern.
#
# NETWORK CONFIGURATION:
#   • VPC-native (alias IP) mode — required for NEG ingress and Workload Identity
#   • Private cluster — nodes have no public IPs; only control plane endpoint is accessible
#   • Master authorized networks — restrict kubectl access to specific CIDRs
#
# SECURITY FEATURES ENABLED:
#   • Workload Identity         — keyless GCP API auth for pods (see workload_identity.tf)
#   • Shielded nodes            — vTPM + secure boot to prevent node tampering
#   • Binary Authorization      — enforce signed image policy (configure separately)
#   • intra-node visibility     — pod-to-pod traffic visible in VPC Flow Logs
#   • Database encryption       — etcd encryption with CMEK (configured separately)
#   • Cloud Armor integration   — via BackendConfig (already in k8s/networking/)
#
# ADDONS ENABLED:
#   • HttpLoadBalancing         — required for GKE Ingress (k8s/networking/03-ingress.yaml)
#   • HorizontalPodAutoscaling  — required for HPA resources
#   • GcsFuseCsiDriver          — required for model-pvc (k8s/model-provisioning/02-pv.yaml)
#   • GcePersistentDiskCsiDriver — required for standard PVCs if added later
# =============================================================================

# ── GKE Standard Cluster ──────────────────────────────────────────────────────

resource "google_container_cluster" "primary" {
  provider = google

  name                = var.cluster_name
  project             = var.project_id
  location            = var.region # Regional cluster — control plane spans 3 zones for HA
  deletion_protection = true

  # ── Bootstrap: remove the default node pool ───────────────────────────────
  # Required pattern when creating custom node pools via separate resources.
  # The cluster needs ONE node to initialize, then we delete it immediately.
  remove_default_node_pool = true
  initial_node_count       = 1

  # ── Networking ────────────────────────────────────────────────────────────
  network    = google_compute_network.vpc.self_link
  subnetwork = google_compute_subnetwork.gke_subnet.self_link

  # VPC-native (alias IP) networking — required for NEG ingress + Workload Identity
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range" # from networking.tf secondary ranges
    services_secondary_range_name = "services-range"
  }

  # ── Private Cluster ───────────────────────────────────────────────────────
  # Nodes have no public IPs — they access the internet via Cloud NAT.
  # enable_private_endpoint = false means the master endpoint is still publicly
  # accessible, but only from CIDRs in master_authorized_networks_config.
  # Set to true for fully private clusters (CI/CD must be in-VPC).
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Allow external kubectl access (with auth)

    # master_ipv4_cidr_block: The IP range for the GKE control plane's internal
    # VPC peering. Must not overlap with the node subnet or pod/service ranges.
    # /28 = 14 usable IPs — exactly what GKE needs for the control plane.
    master_ipv4_cidr_block = "172.16.0.0/28"
  }

  # ── Master Authorized Networks ────────────────────────────────────────────
  # Restricts which external CIDRs can reach the GKE API server endpoint.
  # "0.0.0.0/0" allows access from anywhere (authenticated via kubeconfig).
  # REPLACE with your office IP or CI/CD runner CIDR for production hardening.
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
  # Enables the GKE Workload Identity feature at the cluster level.
  # Without this, pods cannot impersonate GCP Service Accounts.
  # Format: ${project_id}.svc.id.goog
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
    # (k8s/model-provisioning/02-persistentvolume.yaml uses driver: gcsfuse.csi.storage.gke.io)
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
  # REGULAR channel: receives GKE updates ~2-3 weeks after RAPID channel.
  # Balances stability with access to new features.
  # Options: RAPID (newest), REGULAR (recommended for production), STABLE (oldest)
  release_channel {
    channel = "REGULAR"
  }

  # ── Maintenance Window ────────────────────────────────────────────────────
  # Schedule cluster auto-upgrades and node pool maintenance during low-traffic
  # windows. UTC 02:00–06:00 = late night in US Eastern / Europe morning.
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T02:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU" # Weekends only
    }
  }

  # ── Shielded Nodes ────────────────────────────────────────────────────────
  # Enables vTPM and Integrity Monitoring on all nodes to detect boot-level tampering.
  # Required for CIS GKE Benchmark compliance.
  enable_shielded_nodes = true

  # ── Intra-node Visibility ─────────────────────────────────────────────────
  # Makes pod-to-pod traffic within the same node visible in VPC Flow Logs.
  # Required for security auditing of FastAPI → vLLM internal traffic.
  enable_intranode_visibility = true

  # ── Logging & Monitoring ──────────────────────────────────────────────────
  # SYSTEM_COMPONENTS: kube-apiserver, kube-scheduler, kube-controller logs
  # WORKLOADS: container stdout/stderr logs (sent to Cloud Logging)
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
  # Prevent accidental cluster deletion. Terraform will error if you run
  # `terraform destroy` without first setting this to false.
  lifecycle {
    ignore_changes = [
      # GKE auto-updates the master version — ignore to avoid plan drift
      min_master_version,
    ]
  }

  depends_on = [
    google_compute_subnetwork.gke_subnet,
    google_service_account.gke_node_sa,
  ]
}

# ── System Node Pool ──────────────────────────────────────────────────────────
# Runs: kube-system pods, kube-dns, kube-proxy, GKE metadata server,
#       Cloud Logging/Monitoring agents, GKE Ingress controller, Cloud Armor.
# Does NOT run: FastAPI, vLLM, model-download Job (those go on GPU pool or
#   have explicit nodeSelector for the gpu-pool).
#
# WHY SEPARATE SYSTEM AND GPU POOLS?
#   • Cost: system pool uses e2-standard-4 (~$0.13/hr), GPU pool uses g2-standard-12
#     + L4 (~$0.70/hr spot). Running system pods on GPU nodes wastes expensive GPU time.
#   • Isolation: a kube-system OOMKill cannot preempt GPU-scheduled vLLM pods.
#   • Scaling: GPU pool scales independently (based on GPU utilisation).
#   • Node images: system pool uses COS (Container-Optimized OS), GPU pool uses
#     COS with GPU drivers (set in node_pool_gpu.tf).

resource "google_container_node_pool" "system_pool" {
  provider = google

  name     = local.system_node_pool_name
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.primary.name

  # ── Auto-scaling ──────────────────────────────────────────────────────────
  autoscaling {
    min_node_count  = var.system_node_min_count # per zone (1 per zone × 3 zones = 3 total min)
    max_node_count  = var.system_node_max_count # per zone (3 per zone × 3 zones = 9 total max)
    location_policy = "BALANCED"                # spread nodes evenly across zones
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
      # Only cloud-platform scope needed — IAM controls actual permissions via SA roles
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # ── Disk Configuration ────────────────────────────────────────────────
    disk_size_gb = 100           # System node boot disk: 100 GB for OS, kubelet state, image cache
    disk_type    = "pd-balanced" # Balanced PD: good IOPS at lower cost than pd-ssd

    # ── OS Image ─────────────────────────────────────────────────────────
    # cos_containerd: Container-Optimized OS with containerd runtime (CRI)
    # WHY cos_containerd?
    #   • Hardened OS: read-only root filesystem, no package manager
    #   • Maintained by Google with security patches delivered via node auto-upgrade
    #   • containerd is the CRI used by Kubernetes (Docker Engine is deprecated)
    image_type = "COS_CONTAINERD"

    # ── Workload Identity on Nodes ────────────────────────────────────────
    workload_metadata_config {
      # GKE_METADATA: enables Workload Identity; the metadata server on the node
      # issues GCP credentials to pods based on the K8s SA annotation.
      # Without this, Workload Identity bindings in workload_identity.tf have no effect.
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

    # ── Node Taints ───────────────────────────────────────────────────────
    # No taints on system pool — GKE system pods (kube-dns, etc.) do not have
    # tolerations for custom taints. Taints are ONLY on the GPU pool.
  }

  lifecycle {
    ignore_changes = [
      # GKE manages node version within the release channel — ignore drift
      version,
    ]
  }

  depends_on = [google_container_cluster.primary]
}
