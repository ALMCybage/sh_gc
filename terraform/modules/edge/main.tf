/**
 * The external HTTPS load balancer, built here rather than by the GKE Ingress.
 *
 * WHY THIS MODULE EXISTS
 * The architecture puts the React SPA (Cloud Storage + Cloud CDN) and the API (GKE
 * pods) on the SAME hostname, so session cookies can stay HttpOnly + SameSite=Lax
 * with no CORS anywhere. The GKE Ingress controller cannot express that: it only
 * creates Service backends, never a Cloud Storage backend bucket. So the load
 * balancer is defined here and the cluster exposes its pods through a *standalone*
 * NEG that this module attaches to a backend service.
 *
 * Routing:
 *   /api/*, /sanctum/*, /healthz, /readyz  -> web-api pods
 *   everything else                        -> the SPA bucket, cached at the edge
 */

# ---------------------------------------------------------------------------
# Static anycast IP
# ---------------------------------------------------------------------------

resource "google_compute_global_address" "lb" {
  name    = "${var.name_prefix}-lb-ip"
  project = var.project_id
}

# ---------------------------------------------------------------------------
# Cloud Armor: WAF and DDoS, evaluated before anything reaches the cluster
# ---------------------------------------------------------------------------

resource "google_compute_security_policy" "armor" {
  name    = "${var.name_prefix}-armor"
  project = var.project_id

  description = "Edge WAF for the Sequifi platform"

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      # Learns normal traffic and flags anomalies. Worth having on a multi-tenant
      # endpoint where one tenant's traffic pattern is not the whole picture.
      enable          = true
      rule_visibility = "STANDARD"
    }
  }

  /**
   * Per-IP rate limit, enforced at the edge.
   *
   * This runs before a pod is involved, so a flood never consumes cluster capacity
   * and never eats into a tenant's application-level budget (the Laravel limiter).
   * Two layers, two purposes: this one stops abuse, the application one enforces
   * fairness between tenants.
   */
  rule {
    action   = "rate_based_ban"
    priority = 1000
    preview  = false

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = var.rate_limit_per_minute
        interval_sec = 60
      }

      ban_duration_sec = 300
    }

    description = "Per-IP rate limit with a 5 minute ban"
  }

  /**
   * OWASP preconfigured rules at sensitivity 1.
   *
   * Sensitivity 1 only. Higher levels produce false positives on JSON bodies, and a
   * WAF that blocks legitimate payroll submissions is worse than one that catches
   * less: the first thing anyone does after a false positive is disable it entirely.
   * Raise it once the logs show what real traffic looks like.
   */
  dynamic "rule" {
    for_each = var.waf_rules

    content {
      action   = var.waf_preview_only ? "preview" : "deny(403)"
      priority = rule.value.priority
      preview  = var.waf_preview_only

      match {
        expr {
          expression = "evaluatePreconfiguredWaf('${rule.value.rule_set}', {'sensitivity': ${rule.value.sensitivity}})"
        }
      }

      description = rule.value.description
    }
  }

  # Required terminal rule.
  rule {
    action   = "allow"
    priority = 2147483647

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    description = "Default allow"
  }
}

# ---------------------------------------------------------------------------
# API backend: the GKE pods, via a standalone NEG
# ---------------------------------------------------------------------------

/**
 * Health check on /healthz, which deliberately touches no dependency.
 *
 * If it checked Cloud SQL, a database blip would make the load balancer declare
 * every backend dead and return 502 for everything - including the requests that do
 * not need the database. Readiness (which does check dependencies) removes an
 * individual pod from the NEG instead, which is the correct granularity.
 */
resource "google_compute_health_check" "api" {
  name    = "${var.name_prefix}-api-hc"
  project = var.project_id

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 1
  unhealthy_threshold = 3

  http_health_check {
    request_path = "/healthz"
    port         = var.api_container_port
  }

  log_config {
    enable = true
  }
}

resource "google_compute_backend_service" "api" {
  name    = "${var.name_prefix}-api"
  project = var.project_id

  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"

  # Must exceed the application's own timeout so the LB is not the thing that
  # cuts a slow-but-working request short.
  timeout_sec = var.backend_timeout_sec

  health_checks   = [google_compute_health_check.api.id]
  security_policy = google_compute_security_policy.armor.id

  # Below the pods' terminationGracePeriodSeconds (60), so a pod finishes draining
  # before Kubernetes kills it. Get this wrong and rollouts throw 502s.
  connection_draining_timeout_sec = var.connection_draining_sec

  log_config {
    enable      = true
    sample_rate = var.lb_log_sample_rate
  }

  /**
   * NEGs are attached here, one per zone the pods run in.
   *
   * They are created by the Kubernetes Service annotation (see
   * deploy/k8s/31-standalone-neg.yaml), which means they do not exist until the
   * workload is deployed. That is a genuine ordering dependency: Terraform runs
   * first, so this list is passed in and is empty on the very first apply. The
   * bootstrap sequence applies infrastructure, deploys the workload, then re-applies
   * with the NEGs populated.
   */
  dynamic "backend" {
    for_each = var.api_neg_self_links

    content {
      group                 = backend.value
      balancing_mode        = "RATE"
      max_rate_per_endpoint = var.max_rate_per_endpoint
      capacity_scaler       = 1.0
    }
  }

  lifecycle {
    # The GKE NEG controller adds and removes endpoints continuously; Terraform must
    # not try to reconcile that churn.
    ignore_changes = [backend]
  }
}

# ---------------------------------------------------------------------------
# Frontend backend: the SPA bucket, cached at the edge
# ---------------------------------------------------------------------------

resource "google_compute_backend_bucket" "frontend" {
  name        = "${var.name_prefix}-frontend"
  project     = var.project_id
  bucket_name = var.frontend_bucket
  enable_cdn  = true

  cdn_policy {
    cache_mode = "CACHE_ALL_STATIC"
    # Respects the per-object Cache-Control that deploy-frontend.sh sets: one year
    # immutable for hashed assets, no-store for index.html.
    client_ttl  = 3600
    default_ttl = 3600
    max_ttl     = 31536000

    negative_caching = true

    negative_caching_policy {
      code = 404
      ttl  = 60
    }

    # Serve stale content while revalidating, so a brief GCS hiccup does not become
    # a frontend outage.
    serve_while_stale = 86400
  }
}

# ---------------------------------------------------------------------------
# URL map: the split
# ---------------------------------------------------------------------------

resource "google_compute_url_map" "https" {
  name    = "${var.name_prefix}-url-map"
  project = var.project_id

  # Anything not matched below is the SPA.
  default_service = google_compute_backend_bucket.frontend.id

  /**
   * One path matcher shared by every tenant hostname.
   *
   * Tenant routing happens inside the application, from the Host header. That is
   * what lets one deployment serve 150+ tenants without the URL map growing a rule
   * per tenant - and it is why onboarding a tenant is a DNS record plus a
   * certificate domain, not an edge change.
   */
  host_rule {
    hosts        = var.domains
    path_matcher = "sequifi"
  }

  path_matcher {
    name            = "sequifi"
    default_service = google_compute_backend_bucket.frontend.id

    path_rule {
      paths   = ["/api/*", "/sanctum/*", "/healthz", "/readyz"]
      service = google_compute_backend_service.api.id
    }
  }
}

# Port 80 exists only to redirect. No application traffic is served over HTTP.
resource "google_compute_url_map" "http_redirect" {
  name    = "${var.name_prefix}-http-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------

resource "google_compute_ssl_policy" "modern" {
  name    = "${var.name_prefix}-ssl-policy"
  project = var.project_id

  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

/**
 * Certificate Manager rather than a classic managed certificate.
 *
 * A classic cert covers up to 100 domains, and this platform is aimed at 150+
 * tenant subdomains. Certificate Manager supports a wildcard (*.sequifi.com), which
 * turns tenant onboarding into a DNS record and nothing else.
 *
 * A wildcard needs DNS authorisation, so the zone has to be reachable by Google.
 */
resource "google_certificate_manager_dns_authorization" "wildcard" {
  count = var.use_wildcard_certificate ? 1 : 0

  name        = "${var.name_prefix}-dns-auth"
  project     = var.project_id
  domain      = var.base_domain
  description = "Authorises the wildcard certificate for *.${var.base_domain}"
}

resource "google_certificate_manager_certificate" "wildcard" {
  count = var.use_wildcard_certificate ? 1 : 0

  name    = "${var.name_prefix}-wildcard"
  project = var.project_id

  managed {
    domains            = ["*.${var.base_domain}", var.base_domain]
    dns_authorizations = [google_certificate_manager_dns_authorization.wildcard[0].id]
  }
}

resource "google_certificate_manager_certificate_map" "primary" {
  count = var.use_wildcard_certificate ? 1 : 0

  name    = "${var.name_prefix}-cert-map"
  project = var.project_id
}

resource "google_certificate_manager_certificate_map_entry" "wildcard" {
  count = var.use_wildcard_certificate ? 1 : 0

  name         = "${var.name_prefix}-wildcard-entry"
  project      = var.project_id
  map          = google_certificate_manager_certificate_map.primary[0].name
  certificates = [google_certificate_manager_certificate.wildcard[0].id]
  matcher      = "PRIMARY"
}

# Fallback for a small, fixed tenant list: simpler, no DNS authorisation needed.
resource "google_compute_managed_ssl_certificate" "explicit" {
  count = var.use_wildcard_certificate ? 0 : 1

  name    = "${var.name_prefix}-cert"
  project = var.project_id

  managed {
    domains = var.domains
  }

  lifecycle {
    # A cert cannot have its domain list edited; adding a tenant means a new cert
    # attached before the old one is removed.
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Frontends
# ---------------------------------------------------------------------------

resource "google_compute_target_https_proxy" "https" {
  name    = "${var.name_prefix}-https-proxy"
  project = var.project_id
  url_map = google_compute_url_map.https.id

  ssl_policy = google_compute_ssl_policy.modern.id

  certificate_map  = var.use_wildcard_certificate ? "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.primary[0].id}" : null
  ssl_certificates = var.use_wildcard_certificate ? null : [google_compute_managed_ssl_certificate.explicit[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name    = "${var.name_prefix}-https"
  project = var.project_id

  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "${var.name_prefix}-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name    = "${var.name_prefix}-http"
  project = var.project_id

  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
