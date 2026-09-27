/**
 * GKE Autopilot cluster.
 *
 * Autopilot rather than Standard because this platform's scaling problem is pods,
 * not nodes: the worker pool goes 3 -> 20 on queue depth and the web tier 3 -> 30
 * on CPU. With Autopilot there is no node pool to size, no capacity to leave idle
 * as headroom, and billing follows pod requests. The trade is less control - no
 * DaemonSets on the host, no privileged containers, enforced resource requests -
 * all of which this workload is happy to accept.
 *
 * Workload Identity is always on in Autopilot, which is the property the
 * application depends on: pods get short-lived credentials from the metadata
 * server and no service-account key file exists anywhere.
 */

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.region

  enable_autopilot = true

  network    = var.network_id
  subnetwork = var.subnet_id

  # Deletion protection on by default; prod overrides nothing, dev sets false.
  deletion_protection = var.deletion_protection

  release_channel {
    # REGULAR balances "not the bleeding edge" against "still getting security
    # patches without manual upgrades". RAPID moves too fast for a payroll system.
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    # Nodes have no public IPs; egress goes through Cloud NAT.
    enable_private_nodes = true

    # The control plane endpoint stays public but is restricted below. A fully
    # private endpoint needs a bastion or a VPN for kubectl and CI, which is the
    # right answer for a regulated environment and overkill for this sample.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
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

  # Managed Service for Prometheus. The worker exposes /metrics and the HPA scales
  # on Pub/Sub backlog, both of which need collection to be running.
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "CONTROLLER_MANAGER", "SCHEDULER"]

    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Scans running workloads for known vulnerabilities and surfaces them in the
  # security posture dashboard.
  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  # Encrypts Secrets at rest with a customer-managed key rather than only Google's
  # default envelope encryption.
  dynamic "database_encryption" {
    for_each = var.database_encryption_key == null ? [] : [1]

    content {
      state    = "ENCRYPTED"
      key_name = var.database_encryption_key
    }
  }

  maintenance_policy {
    recurring_window {
      # Sunday early morning UTC: the quietest window for a payroll workload, which
      # peaks at month end and mid-month.
      start_time = "2026-01-04T02:00:00Z"
      end_time   = "2026-01-04T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SU"
    }
  }

  # Cost attribution per namespace, exported to BigQuery. In a multi-tenant
  # platform this is how "what does tenant growth actually cost" gets answered.
  dynamic "resource_usage_export_config" {
    for_each = var.usage_export_dataset == null ? [] : [1]

    content {
      enable_network_egress_metering       = true
      enable_resource_consumption_metering = true

      bigquery_destination {
        dataset_id = var.usage_export_dataset
      }
    }
  }

  resource_labels = var.labels

  lifecycle {
    # Autopilot manages node config itself; Terraform must not fight it.
    ignore_changes = [node_config]
  }

  depends_on = [var.api_dependencies]
}
