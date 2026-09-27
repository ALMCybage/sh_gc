/**
 * VPC for the platform.
 *
 * Two things here are load-bearing:
 *
 * 1. Private Service Access (the reserved range + peering). Cloud SQL and
 *    Memorystore get private IPs inside this range, which is what lets the
 *    database have no public IP at all. Without it, Cloud SQL can only be reached
 *    over the internet or through the proxy's public path.
 *
 * 2. Secondary ranges for pods and services. GKE needs them defined on the subnet
 *    before the cluster is created; adding them afterwards means recreating the
 *    cluster.
 */

resource "google_compute_network" "vpc" {
  name    = "${var.name_prefix}-vpc"
  project = var.project_id

  # Subnets are declared explicitly below. Auto mode would create one per region
  # with ranges we do not control, which collides with peered networks later.
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Sequifi platform network"
}

resource "google_compute_subnetwork" "primary" {
  name          = "${var.name_prefix}-${var.region}"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Required for private Google Access from nodes without external IPs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    # 10% sampling: enough to investigate a connectivity problem without paying to
    # log every packet in a busy cluster.
    flow_sampling = 0.1
    metadata      = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Private Service Access: gives Cloud SQL and Memorystore private IPs
# ---------------------------------------------------------------------------

resource "google_compute_global_address" "private_services" {
  name    = "${var.name_prefix}-psa-range"
  project = var.project_id

  purpose = "VPC_PEERING"
  # /16 is generous, but the range cannot be resized after services are peered
  # into it, and running out means no new Cloud SQL instances.
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]

  # Without this, destroying the connection can leave the peering half-removed and
  # block re-creation.
  deletion_policy = "ABANDON"
}

# ---------------------------------------------------------------------------
# Egress: NAT so private nodes can reach Artifact Registry, APIs and the internet
# ---------------------------------------------------------------------------

resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name    = "${var.name_prefix}-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.router.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

/**
 * The load balancer health checker and the Google Front End reach pods from these
 * two ranges. They are fixed, documented Google ranges - not arbitrary.
 *
 * Without this rule the backend service marks every pod unhealthy and the edge
 * returns 502, which is a confusing failure because the pods themselves are fine.
 */
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.name_prefix}-allow-lb-health-checks"
  project = var.project_id
  network = google_compute_network.vpc.name

  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  allow {
    protocol = "tcp"
    ports    = ["8080", "8081"]
  }

  description = "GCP load balancer health checks and Google Front End to pod ports"
}

resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${var.name_prefix}-deny-all-ingress"
  project = var.project_id
  network = google_compute_network.vpc.name

  direction = "INGRESS"
  # Lowest priority: an explicit default-deny that every allow rule above beats.
  # Makes the intent visible instead of relying on the implied default.
  priority      = 65000
  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  description = "Explicit default deny; documents that ingress is allow-listed"
}
