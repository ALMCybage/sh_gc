#!/usr/bin/env bash
#
# Bootstrap a cluster from nothing to running, in the only order that works.
#
#   PROJECT_ID=my-project ENVIRONMENT=prod ./bootstrap/run-all.sh
#
# Every step is idempotent, so a failure part way through can be fixed and the whole
# script re-run rather than resumed by hand.
#
# WHY THE ORDER MATTERS
# There are three genuine ordering constraints, and getting any of them wrong produces
# a confusing failure rather than a clear one:
#
#   1. Secrets must exist before the pods that mount them, or the pods crash-loop with
#      "secret not found" and ArgoCD reports Degraded for a reason unrelated to the
#      manifests.
#   2. The Argo Rollouts CRDs must exist before the application's Rollout resources, or
#      the first sync fails with "no matches for kind Rollout".
#   3. The load balancer's NEGs are created BY the workload, so the edge has no
#      backends until after the first deploy. Terraform therefore runs twice - and
#      between the two runs the platform is reachable only from inside the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export PROJECT_ID="${PROJECT_ID:?export PROJECT_ID}"
export ENVIRONMENT="${ENVIRONMENT:-dev}"
export REGION="${REGION:-us-central1}"
export APP_NAMESPACE="${APP_NAMESPACE:-sequifi}"
export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
export CLUSTER_NAME="${CLUSTER_NAME:-sequifi-${ENVIRONMENT}-autopilot}"
export GITOPS_REPO="${GITOPS_REPO:-https://github.com/your-org/sequifi.git}"

step() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$1"
}

note() {
  printf '    %s\n' "$1"
}

step "Bootstrapping ${CLUSTER_NAME} (${ENVIRONMENT}) in ${PROJECT_ID}"
note "region:    ${REGION}"
note "namespace: ${APP_NAMESPACE}"

"${SCRIPT_DIR}/00-prereqs.sh"
"${SCRIPT_DIR}/10-cluster-access.sh"
"${SCRIPT_DIR}/20-addons.sh"
"${SCRIPT_DIR}/30-secrets.sh"
"${SCRIPT_DIR}/40-argocd.sh"
"${SCRIPT_DIR}/50-first-sync.sh"
"${SCRIPT_DIR}/60-verify.sh"

cat <<EOF

$(printf '\033[1;32m')Bootstrap complete.$(printf '\033[0m')

Remaining manual steps, both of which need information that only exists now:

  1. Attach the NEGs to the load balancer. They were created by the workload that has
     just been deployed, so Terraform could not know about them on the first apply:

       gcloud compute network-endpoint-groups list \\
         --filter="name=web-api-neg" --format="value(selfLink)"

     Put the results in terraform/envs/${ENVIRONMENT}/terraform.tfvars as
     api_neg_self_links, then:

       cd terraform/envs/${ENVIRONMENT} && terraform apply

     Until this is done the load balancer has no backends and returns 502.

  2. Create the DNS records from the Terraform output, then wait for the certificate:

       terraform -chdir=terraform/envs/${ENVIRONMENT} output dns_records_required
       gcloud certificate-manager certificates list

     Provisioning takes 15-60 minutes AFTER DNS resolves.

  3. Publish the SPA:

       PROJECT_ID=${PROJECT_ID} ./deploy/gcp/deploy-frontend.sh

Then verify end to end:

  ./scripts/smoke.sh https://acme.\${BASE_DOMAIN} acme
EOF
