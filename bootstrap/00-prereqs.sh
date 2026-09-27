#!/usr/bin/env bash
#
# Fail early, with a useful message, rather than half way through with a cryptic one.
set -euo pipefail

printf '\n\033[1;36m==> Checking prerequisites\033[0m\n'

missing=0

require() {
  local tool="$1" hint="$2"

  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf '    \033[31mmissing\033[0m %-10s %s\n' "${tool}" "${hint}"
    missing=1
  else
    printf '    ok      %-10s %s\n' "${tool}" "$(${tool} version --short 2>/dev/null | head -1 || ${tool} --version 2>/dev/null | head -1 || echo)"
  fi
}

require gcloud   "https://cloud.google.com/sdk/docs/install"
require kubectl  "gcloud components install kubectl"
require helm     "https://helm.sh/docs/intro/install/"
require terraform "https://developer.hashicorp.com/terraform/install"
require jq       "https://jqlang.github.io/jq/download/"

if [[ "${missing}" -ne 0 ]]; then
  echo
  echo "Install the missing tools and re-run." >&2
  exit 1
fi

# An expired credential produces failures that look like permission problems.
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  echo "    no active gcloud credential; run: gcloud auth login" >&2
  exit 1
fi

if ! gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    cannot read project ${PROJECT_ID}; check the id and your permissions" >&2
  exit 1
fi

printf '    ok      project    %s\n' "${PROJECT_ID}"

# The infrastructure has to exist first. Bootstrapping against a cluster that is not
# there produces a long chain of unhelpful kubectl errors.
if ! gcloud container clusters describe "${CLUSTER_NAME}" \
      --region "${REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  cat >&2 <<EOF

    Cluster ${CLUSTER_NAME} does not exist.

    Run Terraform first:

      cd terraform/envs/${ENVIRONMENT}
      terraform init -backend-config="bucket=${PROJECT_ID}-sequifi-tfstate"
      terraform apply

EOF
  exit 1
fi

printf '    ok      cluster    %s\n' "${CLUSTER_NAME}"
