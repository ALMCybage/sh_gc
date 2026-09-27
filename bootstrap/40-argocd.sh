#!/usr/bin/env bash
#
# Install ArgoCD and hand it the app-of-apps.
#
# This is the last thing installed imperatively. Everything after this point is
# declared in Git, which is the property that makes the cluster reproducible: recovering
# it is running this script again, not following a runbook of Helm commands.
set -euo pipefail

printf '\n\033[1;36m==> Installing ArgoCD\033[0m\n'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" --create-namespace \
  --version 7.7.5 \
  --set configs.params."server\.insecure"=true \
  --set controller.replicas=1 \
  --set repoServer.replicas=2 \
  --set server.replicas=2 \
  --set applicationSet.replicas=2 \
  --set notifications.enabled=true \
  --wait --timeout 10m >/dev/null

printf '    argocd installed\n'

# ---------------------------------------------------------------------------
# Workload Identity for the repo server, so it can pull image metadata from Artifact
# Registry without a key file.
# ---------------------------------------------------------------------------
kubectl annotate serviceaccount argocd-repo-server \
  --namespace "${ARGOCD_NAMESPACE}" \
  "iam.gke.io/gcp-service-account=sequifi-${ENVIRONMENT}-argocd@${PROJECT_ID}.iam.gserviceaccount.com" \
  --overwrite >/dev/null

# ---------------------------------------------------------------------------
# Slack notifications for sync outcomes.
#
# Without this an aborted canary is silent: the rollback works, the previous revision
# keeps serving, and nobody learns the deploy failed until they wonder why their change
# is not live.
# ---------------------------------------------------------------------------
if gcloud secrets describe "sequifi-${ENVIRONMENT}-slack-webhook" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  SLACK_TOKEN="$(gcloud secrets versions access latest \
    --secret="sequifi-${ENVIRONMENT}-slack-webhook" --project "${PROJECT_ID}")"

  kubectl create secret generic argocd-notifications-secret \
    --namespace "${ARGOCD_NAMESPACE}" \
    --from-literal=slack-token="${SLACK_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  printf '    slack notifications configured\n'
else
  printf '    slack notifications skipped (no webhook in Secret Manager)\n'
fi

# ---------------------------------------------------------------------------
# Projects first, then the app-of-apps.
#
# The Applications reference the projects, so applying them in the other order fails
# with "application references undefined project".
# ---------------------------------------------------------------------------
printf '    applying AppProjects\n'
sed "s|https://github.com/your-org/sequifi.git|${GITOPS_REPO}|g" \
  "${ROOT}/gitops/argocd/project.yaml" | kubectl apply -f - >/dev/null

printf '    applying app-of-apps\n'
sed "s|https://github.com/your-org/sequifi.git|${GITOPS_REPO}|g" \
  "${ROOT}/gitops/argocd/app-of-apps.yaml" | kubectl apply -f - >/dev/null

printf '    ArgoCD will now build the rest of the cluster from Git\n'
printf '\n    Admin password:\n'
printf '      kubectl -n %s get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d\n' "${ARGOCD_NAMESPACE}"
printf '    UI:\n'
printf '      kubectl -n %s port-forward svc/argocd-server 8080:80\n' "${ARGOCD_NAMESPACE}"
