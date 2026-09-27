#!/usr/bin/env bash
#
# Configure kubectl and confirm the connection actually works.
set -euo pipefail

printf '\n\033[1;36m==> Configuring cluster access\033[0m\n'

gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

# A successful get-credentials does not mean the API is reachable: if
# master_authorized_networks does not include this machine, every subsequent command
# times out instead of saying why.
if ! kubectl cluster-info --request-timeout=15s >/dev/null 2>&1; then
  cat >&2 <<EOF

    Cannot reach the Kubernetes API.

    The most likely cause is master_authorized_networks not including this machine's
    egress address. Check your current address and add it:

      curl -s https://ifconfig.me

    Then in terraform/envs/${ENVIRONMENT}/terraform.tfvars:

      master_authorized_networks = [
        { cidr_block = "<your-ip>/32", display_name = "operator" },
      ]

EOF
  exit 1
fi

printf '    connected to %s\n' "$(kubectl config current-context)"
