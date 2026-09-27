# Bootstrap

From an empty GCP project to a running platform.

```bash
# 1. Terraform state bucket (once per project, local state, the only chicken-and-egg)
cd terraform/bootstrap-state
terraform init && terraform apply -var project_id=$PROJECT_ID

# 2. Infrastructure
cd ../envs/prod
cp terraform.tfvars.example terraform.tfvars    # fill it in
terraform init -backend-config="bucket=$PROJECT_ID-sequifi-tfstate"
terraform apply

# 3. Cluster: addons, secrets, ArgoCD, first sync
cd ../../..
PROJECT_ID=$PROJECT_ID ENVIRONMENT=prod ./bootstrap/run-all.sh

# 4. Attach the NEGs and re-apply (see "the ordering problem" below)
gcloud compute network-endpoint-groups list \
  --filter="name=web-api-neg" --format="value(selfLink)"
# put those in terraform.tfvars as api_neg_self_links, then:
terraform -chdir=terraform/envs/prod apply

# 5. DNS, then the SPA
terraform -chdir=terraform/envs/prod output dns_records_required
PROJECT_ID=$PROJECT_ID ./deploy/gcp/deploy-frontend.sh
```

## Why the order is what it is

Three real constraints. Each one produces a confusing failure if you get it wrong,
which is why they are worth stating rather than discovering.

**Secrets before pods.** External Secrets has to be running and the Secret Manager
entries have to exist before the application syncs. Otherwise the pods crash-loop on a
missing Secret and ArgoCD reports `Degraded` for a reason that has nothing to do with
the manifests. `30-secrets.sh` checks the Secret Manager entries explicitly so the
error names the missing secret instead.

**CRDs before the resources that use them.** The workloads are `Rollout`s, not
Deployments. Syncing an Application containing a `Rollout` into a cluster without the
Argo Rollouts CRD fails with `no matches for kind "Rollout"`. `20-addons.sh` installs
the operators with Helm and waits for the CRDs to be established; ArgoCD adopts them
afterwards.

**The NEG ordering problem.** This one is inherent, not accidental.

The load balancer needs backends. Its backends are Network Endpoint Groups of pod IPs.
Those NEGs are created by the Kubernetes `Service` annotation — so they do not exist
until the workload is deployed. But the workload is deployed by ArgoCD, which runs
after Terraform.

So Terraform runs twice:

```
terraform apply          # everything except LB backends
  -> bootstrap           # deploy the workload, which creates the NEGs
    -> terraform apply   # attach them
```

Between the two applies the platform is reachable from inside the cluster but the edge
returns 502. That is expected, and `60-verify.sh` says so rather than reporting a
failure.

The alternative would be the GKE Ingress controller, which creates and attaches NEGs
itself — but it cannot put a Cloud Storage backend bucket on the same load balancer, and
the whole point of this edge design is serving the SPA and the API on one origin so
session cookies can stay `HttpOnly` + `SameSite=Lax` with no CORS. Two Terraform applies
is the cost of that.

## What each script does

| Script | Purpose | Idempotent |
|---|---|---|
| `00-prereqs.sh` | Tool and credential checks; fails early with a fix | yes |
| `10-cluster-access.sh` | `get-credentials`, then proves the API is actually reachable | yes |
| `20-addons.sh` | Argo Rollouts, External Secrets, metrics adapter, Prometheus | yes |
| `30-secrets.sh` | Verifies app secrets exist; creates Alertmanager and Grafana ones | yes |
| `40-argocd.sh` | Installs ArgoCD, applies projects and the app-of-apps | yes |
| `50-first-sync.sh` | Waits for convergence; reports what is still pending | yes |
| `60-verify.sh` | Honest status report; does not fail on expected pending items | yes |

Every step is idempotent, so a failure can be fixed and `run-all.sh` re-run from the
top rather than resumed by hand.

## After this, nothing is applied by hand

ArgoCD owns the cluster. CI pushes an image and commits a tag change to
`gitops/apps/overlays/<env>/kustomization.yaml`; ArgoCD notices and rolls out. `selfHeal`
is on, so a `kubectl edit` during an incident is reverted within minutes — the fix has to
be committed, which is what keeps "what is running" answerable by reading Git.

## Recovering a cluster

Because everything after ArgoCD is declarative, cluster recovery is steps 2 and 3 again.
The data is what needs real recovery: Cloud SQL point-in-time recovery (7 day window),
and Firestore PITR for request statuses. See `docs/runbook/disaster-recovery.md`.
