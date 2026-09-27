#!/usr/bin/env bash
#
# Wire up secrets.
#
# The application's own secrets (APP_KEY, DB password, Redis auth) come from Secret
# Manager via External Secrets and need nothing here - Terraform created them and the
# ExternalSecret manifest references them by name. Nothing secret is ever committed.
#
# What DOES need doing here is the handful of secrets that belong to the platform tools
# rather than the application: Alertmanager's PagerDuty key and Slack webhook, and
# Grafana's admin password. Those are created directly because the tools are installed
# by Helm, not by ArgoCD, at this point in the sequence.
set -euo pipefail

printf '\n\033[1;36m==> Configuring secrets\033[0m\n'

kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------------------------------------------------------------------------
# Confirm the application's secrets exist in Secret Manager.
#
# Checking here turns a crash-looping pod (with a message about a missing Secret) into
# a clear statement about which Secret Manager entry is absent.
# ---------------------------------------------------------------------------
for secret in app-key db-password redis-auth; do
  name="sequifi-${ENVIRONMENT}-${secret}"

  if gcloud secrets describe "${name}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    printf '    ok      %s\n' "${name}"
  else
    printf '    \033[31mmissing\033[0m %s\n' "${name}" >&2
    echo "            Terraform creates this. Has terraform apply completed?" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Alertmanager routing credentials.
#
# Read from Secret Manager rather than passed as arguments, so they never appear in a
# shell history or a CI log.
# ---------------------------------------------------------------------------
mk_secret_from_gsm() {
  local k8s_name="$1" k8s_ns="$2" key="$3" gsm_secret="$4"

  if ! gcloud secrets describe "${gsm_secret}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    printf '    skip    %s (no %s in Secret Manager)\n' "${k8s_name}" "${gsm_secret}"
    return 0
  fi

  gcloud secrets versions access latest --secret="${gsm_secret}" --project "${PROJECT_ID}" \
    | kubectl create secret generic "${k8s_name}" \
        --namespace "${k8s_ns}" \
        --from-file="${key}=/dev/stdin" \
        --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null

  printf '    ok      %s/%s\n' "${k8s_ns}" "${k8s_name}"
}

mk_secret_from_gsm alertmanager-pagerduty monitoring service-key "sequifi-${ENVIRONMENT}-pagerduty-key"
mk_secret_from_gsm alertmanager-slack     monitoring webhook-url "sequifi-${ENVIRONMENT}-slack-webhook"

# Grafana admin. Generated if absent rather than defaulting to something guessable.
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  password="$(openssl rand -base64 24)"

  kubectl create secret generic grafana-admin \
    --namespace monitoring \
    --from-literal=username=admin \
    --from-literal=password="${password}" >/dev/null

  # Stored in Secret Manager so it is recoverable, and NOT printed here - a bootstrap
  # log is usually pasted into a ticket.
  if gcloud secrets describe "sequifi-${ENVIRONMENT}-grafana-admin" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    printf '%s' "${password}" | gcloud secrets versions add "sequifi-${ENVIRONMENT}-grafana-admin" \
      --data-file=- --project "${PROJECT_ID}" >/dev/null
  else
    printf '%s' "${password}" | gcloud secrets create "sequifi-${ENVIRONMENT}-grafana-admin" \
      --data-file=- --project "${PROJECT_ID}" >/dev/null
  fi

  printf '    ok      grafana-admin (password stored in Secret Manager)\n'
else
  printf '    ok      grafana-admin (exists)\n'
fi
