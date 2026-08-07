# =============================================================================
# terraform/networking.tf
#
# RESOURCES CREATED:
#   1. google_compute_network       — Custom-mode VPC (no auto-subnets)
#   2. google_compute_subnetwork    — GKE node subnet with secondary IP ranges
#   3. google_compute_router        — Cloud Router (prerequisite for Cloud NAT)
#   4. google_compute_router_nat    — Cloud NAT (private nodes → internet egress)
#
# WHY CUSTOM VPC AND NOT DEFAULT?
#   GCP's default VPC:
#     • Auto-creates subnets in every region with overlapping CIDRs
#     • Cannot be deleted — persists even if unused
#     • Has permissive firewall rules ("allow all internal" by default)
#     • Not suitable for production — violates CIS Benchmark 3.1
#   Custom VPC:
#     • You control every subnet and firewall rule
#     • No implicit rules — deny-all-ingress by default
#     • Supports VPC Peering, Private Service Access, and Shared VPC
#     • Required for GKE VPC-native (alias IP) mode
#
# WHY VPC-NATIVE (ALIAS IP)?
#   GKE has two networking modes:
#     Routes-based: pod IPs are virtual (not routable in VPC) — legacy, deprecated
#     VPC-native:   pod IPs are real VPC IPs from a secondary range — REQUIRED for:
#       • GKE Workload Identity Federation (uses real pod IPs in OIDC tokens)
#       • Network Endpoint Groups (NEG) for direct pod routing from the LB
#       • Cloud Armor policies targeting pod IPs
#       • GKE Dataplane V2 (Cilium-based eBPF networking)
#
# SECONDARY IP RANGES:
#   GKE VPC-native requires TWO secondary ranges on the node subnet:
#   • pods_range     — one /24 per node is carved out automatically by GKE
#                      (with 10.20.0.0/16: up to 256 nodes, each with 254 pod IPs)
#   • services_range — ClusterIP addresses for Kubernetes Services
#                      (10.30.0.0/20 = 4094 service IPs)
#
# CLOUD NAT:
#   GKE nodes are PRIVATE (no public IPs) for security.
#   Private nodes cannot pull Docker images from the internet or reach Hugging Face.
#   Cloud NAT provides outbound-only internet access:
#     • Node → Artifact Registry (pull FastAPI/vLLM images)
#     • model-download Job → Hugging Face Hub (download Mistral-7B weights)
#     • Node → GCP APIs (Logging, Trace, Secret Manager) — these also work via
#       Private Google Access (enabled below) without going through NAT
#
# PRIVATE GOOGLE ACCESS:
#   private_ip_google_access = true enables nodes to reach Google APIs
#   (Cloud Logging, Cloud Trace, Artifact Registry) via Google's internal network
#   WITHOUT going through Cloud NAT — lower latency and no NAT egress cost.
# =============================================================================

# ── 1. VPC Network ────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name    = var.network_name
  project = var.project_id

  # WHY auto_create_subnetworks = false?
  #   auto_create_subnetworks creates one subnet per region automatically.
  #   Custom-mode (false) means YOU define every subnet — full control.
  auto_create_subnetworks = false

  # WHY REGIONAL routing_mode?
  #   REGIONAL: Cloud Routers advertise routes only within the same region.
  #   GLOBAL:   Cloud Routers learn routes across ALL regions (needed for
  #             multi-region clusters or VPN to on-prem). Use GLOBAL if you
  #             plan to expand to multi-region. REGIONAL is cheaper and simpler.
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
  # Allows VMs without public IPs to reach Google APIs (Logging, Trace, AR)
  # through Google's internal network instead of via Cloud NAT.
  # Reduces latency and eliminates NAT egress fees for GCP API traffic.
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
  # Flow logs capture network traffic metadata for security audit and debugging.
  # aggregation_interval: 5 seconds is a good balance of detail vs cost.
  # Disable in dev to reduce Cloud Logging costs.
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5 # Sample 50% of flows (full = 1.0, off = 0.0)
    metadata             = "INCLUDE_ALL_METADATA"
  }

  description = "GKE node subnet with VPC-native secondary ranges for pods and services"
}

# ── 3. Cloud Router ───────────────────────────────────────────────────────────
# Cloud Router is a prerequisite for Cloud NAT. It advertises the subnet's
# routes to the Google network infrastructure.

resource "google_compute_router" "nat_router" {
  name    = "${var.network_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.self_link

  bgp {
    # ASN 64514 is in the private range (64512–65534). Required but not used for
    # NAT (only relevant if you add Cloud VPN or Interconnect later).
    asn = 64514
  }

  description = "Cloud Router for Cloud NAT egress from private GKE nodes"
}

# ── 4. Cloud NAT ─────────────────────────────────────────────────────────────
# Provides outbound internet access for private GKE nodes.
# Used for: Docker pulls from Docker Hub, Hugging Face model downloads.

resource "google_compute_router_nat" "nat" {
  name    = "${var.network_name}-nat"
  project = var.project_id
  router  = google_compute_router.nat_router.name
  region  = var.region

  # AUTO_ONLY: GCP automatically allocates external IPs for NAT egress.
  # MANUAL_ONLY: You provide specific static external IPs (needed if a 3rd party
  # allowlists your egress IP). Use MANUAL_ONLY for Hugging Face enterprise access.
  nat_ip_allocate_option = "AUTO_ONLY"

  # ALL_SUBNETWORKS_ALL_IP_RANGES: NAT applies to ALL subnets in this region.
  # LIST_OF_SUBNETWORKS: NAT applies only to specified subnets (more secure).
  # Using LIST_OF_SUBNETWORKS ensures NAT only covers our GKE subnet.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.gke_subnet.self_link
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # ── NAT Logging ──────────────────────────────────────────────────────────────
  # Log NAT translations for security audit and connection debugging.
  # ERRORS_ONLY reduces log volume vs ALL (which logs every connection).
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  # Min ports per VM controls connection concurrency.
  # 64 ports = 64 simultaneous TCP/UDP connections per node.
  # Increase if model-download Job hits "RESOURCE_EXHAUSTED" NAT errors.
  min_ports_per_vm = 64

  # Enable endpoint-independent mapping for UDP NAT traversal (useful for
  # gRPC keep-alives and UDP-based protocols).
  enable_endpoint_independent_mapping = false
}
