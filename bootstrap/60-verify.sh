#!/usr/bin/env bash
#
# Check what actually came up, and report honestly on what did not.
#
# Deliberately does not fail the bootstrap: two of these checks cannot pass until the
# manual post-bootstrap steps are done, and exiting non-zero would make a normal first
# run look broken.
set -uo pipefail

printf '\n\033[1;36m==> Verifying\033[0m\n'

pass() { printf '    \033[32mok\033[0m      %s\n' "$1"; }
warn() { printf '    \033[33mpending\033[0m %s\n' "$1"; }
fail() { printf '    \033[31mfailed\033[0m  %s\n' "$1"; }

# --- CRDs ------------------------------------------------------------------
for crd in rollouts.argoproj.io externalsecrets.external-secrets.io \
           prometheusrules.monitoring.coreos.com applications.argoproj.io; do
  if kubectl get crd "${crd}" >/dev/null 2>&1; then
    pass "crd ${crd}"
  else
    fail "crd ${crd} missing"
  fi
done

# --- Custom metrics API ----------------------------------------------------
# Without this the worker HPA is blind to queue depth and silently stays at
# minReplicas while the backlog grows.
if kubectl get apiservice v1beta2.custom.metrics.k8s.io >/dev/null 2>&1 \
   || kubectl get apiservice v1beta1.external.metrics.k8s.io >/dev/null 2>&1; then
  pass "external metrics API registered (worker HPA can see Pub/Sub backlog)"
else
  fail "external metrics API not registered - the worker HPA will not scale on queue depth"
fi

# --- Secrets ---------------------------------------------------------------
if kubectl get secret app-secrets -n "${APP_NAMESPACE}" >/dev/null 2>&1; then
  pass "app-secrets materialised from Secret Manager"
else
  warn "app-secrets not present yet (External Secrets may still be reconciling)"
fi

# --- Workloads -------------------------------------------------------------
for rollout in web-api worker; do
  status="$(kubectl get rollout "${rollout}" -n "${APP_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "absent")"

  case "${status}" in
    Healthy) pass "rollout ${rollout} healthy" ;;
    Progressing|Paused) warn "rollout ${rollout} is ${status}" ;;
    absent) warn "rollout ${rollout} not created yet" ;;
    *) fail "rollout ${rollout} is ${status}" ;;
  esac
done

# --- Application readiness -------------------------------------------------
ready="$(kubectl get pods -n "${APP_NAMESPACE}" -l app=web-api \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  2>/dev/null | grep -c True || true)"

if [[ "${ready:-0}" -gt 0 ]]; then
  pass "${ready} web-api pod(s) ready"

  # /readyz names which dependency is unhealthy, which is far more useful than a pod
  # simply not becoming ready.
  printf '    readiness detail:\n'
  kubectl run readyz-probe --rm -i --restart=Never \
    --namespace "${APP_NAMESPACE}" \
    --image=curlimages/curl:8.11.1 \
    --command -- curl -s --max-time 10 "http://web-api.${APP_NAMESPACE}.svc.cluster.local/readyz" \
    2>/dev/null | head -c 500 | sed 's/^/      /' || printf '      (probe could not run)\n'
  echo
else
  warn "no web-api pods ready yet"
fi

# --- NEGs ------------------------------------------------------------------
# Created by the Service, consumed by the Terraform-managed load balancer. Until they
# are attached the edge has no backends.
neg_count="$(gcloud compute network-endpoint-groups list \
  --filter="name=web-api-neg" --format="value(name)" --project "${PROJECT_ID}" 2>/dev/null | wc -l | tr -d ' ')"

if [[ "${neg_count:-0}" -gt 0 ]]; then
  pass "${neg_count} NEG(s) created by the Service"
  warn "attach them to the load balancer: see the note at the end of run-all.sh"
else
  warn "no NEGs yet (they appear once web-api pods are running)"
fi
