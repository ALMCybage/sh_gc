#!/usr/bin/env bash
#
# Install the operators whose CRDs everything else depends on.
#
# ArgoCD will manage these going forward (see gitops/argocd/applications/), but they
# have to exist BEFORE the first sync: an Application containing a Rollout cannot be
# synced into a cluster that has no Rollout CRD. Installing them here and letting
# ArgoCD adopt them afterwards avoids that chicken-and-egg.
set -euo pipefail

printf '\n\033[1;36m==> Installing cluster addons\033[0m\n'

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

# --- Argo Rollouts ---------------------------------------------------------
# The application's workloads are Rollouts, not Deployments, so this is a hard
# dependency of the first sync.
printf '    argo-rollouts\n'
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --version 2.38.0 \
  --set controller.replicas=2 \
  --set dashboard.enabled=true \
  --set podSecurityContext.runAsNonRoot=true \
  --wait --timeout 5m >/dev/null

# --- External Secrets ------------------------------------------------------
# Materialises Kubernetes Secrets from Secret Manager. Must be running before the
# application syncs, or the pods mount a Secret that does not exist yet.
printf '    external-secrets\n'
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version 0.10.5 \
  --set installCRDs=true \
  --set replicaCount=2 \
  --wait --timeout 5m >/dev/null

# --- Custom Metrics Adapter ------------------------------------------------
# The worker HPA scales on Pub/Sub backlog, which is a Cloud Monitoring metric. Without
# this the HPA cannot see the queue at all and sits at minReplicas while work piles up.
printf '    custom-metrics-stackdriver-adapter\n'
kubectl apply -k "$(dirname "${BASH_SOURCE[0]}")/../gitops/platform/custom-metrics-adapter" >/dev/null

METRICS_SA="sequifi-${ENVIRONMENT}-metrics-adapter@${PROJECT_ID}.iam.gserviceaccount.com"
kubectl annotate serviceaccount custom-metrics-stackdriver-adapter \
  --namespace custom-metrics \
  "iam.gke.io/gcp-service-account=${METRICS_SA}" \
  --overwrite >/dev/null

# --- kube-prometheus-stack -------------------------------------------------
# Argo Rollouts' canary analysis queries this Prometheus synchronously, so a rollout
# cannot be judged until it is running. Cloud Monitoring's ingestion delay is too long
# for that decision.
printf '    kube-prometheus-stack (this one takes a few minutes)\n'
VALUES="$(dirname "${BASH_SOURCE[0]}")/../gitops/platform/observability/kube-prometheus-values.yaml"

sed "s/PROJECT_ID/${PROJECT_ID}/g" "${VALUES}" > /tmp/kps-values.yaml

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 65.5.1 \
  --values /tmp/kps-values.yaml \
  --wait --timeout 15m >/dev/null

rm -f /tmp/kps-values.yaml

printf '    waiting for the Rollout CRD to be established\n'
kubectl wait --for=condition=established --timeout=120s \
  crd/rollouts.argoproj.io >/dev/null

printf '    waiting for the ExternalSecret CRD to be established\n'
kubectl wait --for=condition=established --timeout=120s \
  crd/externalsecrets.external-secrets.io >/dev/null

printf '    addons ready\n'
