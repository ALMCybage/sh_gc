#!/usr/bin/env bash
#
# Wait for ArgoCD to converge, and substitute the placeholders it cannot know.
#
# The Kustomize overlays contain PROJECT_ID and REDIS_HOST_PLACEHOLDER because those
# values come from Terraform outputs, not from Git. In a real setup this is where
# ArgoCD's ApplicationSet generators or a `kustomize edit` in CI would fill them in;
# here the substitution is explicit so the mechanism is visible rather than magic.
set -euo pipefail

printf '\n\033[1;36m==> First sync\033[0m\n'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Values that only Terraform knows.
# ---------------------------------------------------------------------------
TF_DIR="${ROOT}/terraform/envs/${ENVIRONMENT}"

if [[ -d "${TF_DIR}" ]]; then
  REDIS_HOST="$(terraform -chdir="${TF_DIR}" output -json stack 2>/dev/null | jq -r '.redis_host // empty' || true)"
  SQL_INSTANCE="$(terraform -chdir="${TF_DIR}" output -json stack 2>/dev/null | jq -r '.sql_connection_name // empty' || true)"
else
  REDIS_HOST=""
  SQL_INSTANCE=""
fi

if [[ -z "${REDIS_HOST}" ]]; then
  printf '    \033[33mwarning\033[0m could not read redis_host from Terraform output.\n'
  printf '            The app ConfigMap will keep REDIS_HOST_PLACEHOLDER and pods will\n'
  printf '            fail readiness on the redis check. Patch it manually:\n'
  printf '              kubectl -n %s patch cm app-config --type merge \\\n' "${APP_NAMESPACE}"
  printf '                -p '"'"'{"data":{"REDIS_HOST":"<ip>"}}'"'"'\n'
else
  printf '    redis:  %s\n' "${REDIS_HOST}"
fi

[[ -n "${SQL_INSTANCE}" ]] && printf '    sql:    %s\n' "${SQL_INSTANCE}"

# ---------------------------------------------------------------------------
# Wait for the root Application to appear, then for the children.
# ---------------------------------------------------------------------------
printf '    waiting for the root application\n'

for _ in $(seq 1 30); do
  if kubectl get application sequifi-root -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

printf '    waiting for child applications (up to 10 minutes)\n'

deadline=$(( $(date +%s) + 600 ))

while [[ "$(date +%s)" -lt "${deadline}" ]]; do
  # Anything not Synced+Healthy keeps us waiting. Printed each round so a stuck
  # Application is visible rather than hidden behind a spinner.
  pending="$(kubectl get applications -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
    2>/dev/null | awk '$2 != "Synced" || $3 != "Healthy"' || true)"

  if [[ -z "${pending}" ]]; then
    printf '    all applications synced and healthy\n'
    exit 0
  fi

  printf '      pending: %s\n' "$(echo "${pending}" | awk '{print $1"("$2"/"$3")"}' | tr '\n' ' ')"
  sleep 20
done

printf '\n    \033[33mSome applications did not converge.\033[0m This is often expected on a first run:\n'
printf '      - the app ConfigMap still contains placeholders (see above)\n'
printf '      - the load balancer has no backends until the NEGs are attached\n'
printf '    Inspect with:\n'
printf '      kubectl get applications -n %s\n' "${ARGOCD_NAMESPACE}"
printf '      kubectl describe application sequifi-%s -n %s\n' "${ENVIRONMENT}" "${ARGOCD_NAMESPACE}"
