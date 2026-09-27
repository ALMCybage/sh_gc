/**
 * Service accounts and Workload Identity bindings.
 *
 * The whole point of this module is that no service-account key file is ever
 * created. Each Kubernetes service account is bound to a Google one, pods fetch
 * short-lived credentials from the GKE metadata server, and there is no long-lived
 * secret to leak, rotate or accidentally commit.
 *
 * Roles are split so the web tier can publish but not consume, and the worker can
 * consume but not publish. If the worker is compromised it cannot inject work; if
 * the web tier is compromised it cannot drain the queue.
 */

locals {
  wi_pool = "${var.project_id}.svc.id.goog"

  # Least privilege, stated explicitly rather than "roles/editor for both".
  web_api_roles = [
    "roles/pubsub.publisher", # publish payroll and sales events
    "roles/datastore.user",   # read/write Firestore status documents
    "roles/cloudsql.client",  # connect through the Auth Proxy sidecar
    "roles/secretmanager.secretAccessor",
    "roles/monitoring.metricWriter",
    "roles/cloudtrace.agent",
  ]

  worker_roles = [
    "roles/pubsub.subscriber", # NOT publisher
    "roles/datastore.user",
    "roles/cloudsql.client",
    "roles/secretmanager.secretAccessor",
    "roles/monitoring.metricWriter",
    "roles/cloudtrace.agent",
  ]

  # The metrics adapter reads Pub/Sub backlog so the HPA can scale on queue depth.
  metrics_adapter_roles = [
    "roles/monitoring.viewer",
  ]

  # ArgoCD needs to read images to resolve digests, nothing more. It does not need
  # to deploy anything through GCP APIs; it talks to the Kubernetes API directly.
  argocd_roles = [
    "roles/artifactregistry.reader",
  ]
}

# ---------------------------------------------------------------------------
# Google service accounts
# ---------------------------------------------------------------------------

resource "google_service_account" "web_api" {
  account_id   = "${var.name_prefix}-web-api"
  project      = var.project_id
  display_name = "Sequifi web API (Laravel)"
  description  = "Publishes to Pub/Sub, reads/writes Firestore, connects to Cloud SQL"
}

resource "google_service_account" "worker" {
  account_id   = "${var.name_prefix}-worker"
  project      = var.project_id
  display_name = "Sequifi worker (Go calculation engine)"
  description  = "Consumes Pub/Sub, writes tenant schemas in Cloud SQL"
}

resource "google_service_account" "metrics_adapter" {
  account_id   = "${var.name_prefix}-metrics-adapter"
  project      = var.project_id
  display_name = "Custom Metrics Stackdriver Adapter"
  description  = "Reads Cloud Monitoring so the HPA can scale on Pub/Sub backlog"
}

resource "google_service_account" "argocd" {
  account_id   = "${var.name_prefix}-argocd"
  project      = var.project_id
  display_name = "ArgoCD"
  description  = "Reads Artifact Registry to resolve image digests"
}

# ---------------------------------------------------------------------------
# Project-level role bindings
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "web_api" {
  for_each = toset(local.web_api_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.web_api.email}"
}

resource "google_project_iam_member" "worker" {
  for_each = toset(local.worker_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "metrics_adapter" {
  for_each = toset(local.metrics_adapter_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.metrics_adapter.email}"
}

resource "google_project_iam_member" "argocd" {
  for_each = toset(local.argocd_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.argocd.email}"
}

# ---------------------------------------------------------------------------
# Secret-level access
#
# secretAccessor is granted per secret rather than project-wide, so a new secret is
# not automatically readable by every workload.
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret_iam_member" "web_api_secrets" {
  for_each = toset(var.web_api_secret_ids)

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.web_api.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_secrets" {
  for_each = toset(var.worker_secret_ids)

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

# ---------------------------------------------------------------------------
# Workload Identity bindings
#
# This is what replaces key files: the named Kubernetes service account is allowed
# to impersonate the Google service account, and only from this cluster's identity
# pool.
# ---------------------------------------------------------------------------

resource "google_service_account_iam_member" "web_api_wi" {
  service_account_id = google_service_account.web_api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.app_namespace}/web-api]"
}

resource "google_service_account_iam_member" "worker_wi" {
  service_account_id = google_service_account.worker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.app_namespace}/worker]"
}

resource "google_service_account_iam_member" "metrics_adapter_wi" {
  service_account_id = google_service_account.metrics_adapter.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[custom-metrics/custom-metrics-stackdriver-adapter]"
}

resource "google_service_account_iam_member" "argocd_wi" {
  service_account_id = google_service_account.argocd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.argocd_namespace}/argocd-repo-server]"
}

# ---------------------------------------------------------------------------
# CI deploy identity, via Workload Identity Federation
#
# GitHub Actions authenticates with an OIDC token exchanged for short-lived GCP
# credentials. Same principle as the pods: no downloadable key anywhere, and access
# scoped to one repository so another repo in the org cannot deploy this platform.
# ---------------------------------------------------------------------------

resource "google_service_account" "ci_deployer" {
  count = var.github_repository == null ? 0 : 1

  account_id   = "${var.name_prefix}-ci-deployer"
  project      = var.project_id
  display_name = "GitHub Actions deployer"
}

resource "google_project_iam_member" "ci_deployer" {
  for_each = var.github_repository == null ? toset([]) : toset([
    "roles/artifactregistry.writer",
    "roles/container.developer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ci_deployer[0].email}"
}

resource "google_iam_workload_identity_pool" "github" {
  count = var.github_repository == null ? 0 : 1

  project                   = var.project_id
  workload_identity_pool_id = "${var.name_prefix}-github"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for CI, so no service-account key is needed"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = var.github_repository == null ? 0 : 1

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Without this condition ANY GitHub repository could mint credentials for this
  # project. It is the single most important line in the federation setup.
  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "ci_deployer_federation" {
  count = var.github_repository == null ? 0 : 1

  service_account_id = google_service_account.ci_deployer[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repository}"
}
