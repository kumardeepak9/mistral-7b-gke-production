

# ── 1. VPC Network ────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name    = var.network_name
  project = var.project_id

  
  auto_create_subnetworks = false

 
  routing_mode = "REGIONAL"

  # Allows deleting the network even if it has resources (useful for teardown).
  delete_default_routes_on_create = false

  description = "Private VPC for Mistral Inference Gateway GKE cluster"
}

# ── 2. Subnet ─────────────────────────────────────────────────────────────────

resource "google_compute_subnetwork" "gke_subnet" {
  name    = var.subnet_name
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.self_link

  ip_cidr_range = var.subnet_cidr # 10.10.0.0/20 — GKE node IPs

  # ── Private Google Access ────────────────────────────────────────────────────

  private_ip_google_access = true

  # ── Secondary IP Ranges (required for VPC-native GKE) ──────────────────────
  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = var.pods_cidr # 10.20.0.0/16 — pod IPs
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = var.services_cidr # 10.30.0.0/20 — service ClusterIPs
  }

  # ── VPC Flow Logs ────────────────────────────────────────────────────────────
 
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5 # Sample 50% of flows (full = 1.0, off = 0.0)
    metadata             = "INCLUDE_ALL_METADATA"
  }

  description = "GKE node subnet with VPC-native secondary ranges for pods and services"
}

# ── 3. Cloud Router ───────────────────────────────────────────────────────────


resource "google_compute_router" "nat_router" {
  name    = "${var.network_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.self_link

  bgp {

    asn = 64514
  }

  description = "Cloud Router for Cloud NAT egress from private GKE nodes"
}

# ── 4. Cloud NAT ─────────────────────────────────────────────────────────────


resource "google_compute_router_nat" "nat" {
  name    = "${var.network_name}-nat"
  project = var.project_id
  router  = google_compute_router.nat_router.name
  region  = var.region

  
  nat_ip_allocate_option = "AUTO_ONLY"

 
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.gke_subnet.self_link
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # ── NAT Logging ──────────────────────────────────────────────────────────────
 
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  
  min_ports_per_vm = 64

 
  enable_endpoint_independent_mapping = false
}
