# Disaster recovery

What is recoverable, how, and how long it takes.

## What holds state

| Store | Contents | Loss impact | Recovery |
|---|---|---|---|
| **Cloud SQL** | Employees, payroll runs and lines, sales records, users, audit trail | The business data. Unrecoverable elsewhere. | Automated backups (30 days) + PITR (7 days) |
| **Firestore** | Async request statuses | Callers cannot see progress; the underlying work is unaffected | PITR (7 days) |
| **Memorystore** | Sessions, cache, idempotency claims | Users signed out; in-flight idempotency claims lost | None needed — see below |
| **Pub/Sub** | Undelivered work | 7 day retention, so a multi-day outage still recovers | None needed |
| **GCS (frontend)** | The built SPA | Rebuild from Git | Object versioning (10 versions) |
| **Cluster** | Nothing | — | Terraform + bootstrap |

The cluster holds no state. That is deliberate and it is what makes recovery
straightforward: rebuilding it is `terraform apply` then `bootstrap/run-all.sh`.

## Objectives

| | Target | Bounded by |
|---|---|---|
| **RPO** | ≤ 5 minutes | Cloud SQL PITR granularity |
| **RTO** (cluster loss) | ≤ 60 minutes | Autopilot provisioning + bootstrap |
| **RTO** (database restore) | ≤ 2 hours | Restore time for the instance size |

## Scenario 1: cluster loss

The straightforward case. No data is in the cluster.

```bash
# 1. Recreate it
cd terraform/envs/prod
terraform apply          # ~15 min for an Autopilot cluster

# 2. Bootstrap
cd ../../..
PROJECT_ID=$PROJECT_ID ENVIRONMENT=prod ./bootstrap/run-all.sh   # ~20 min

# 3. NEGs, then re-apply so the LB has backends
gcloud compute network-endpoint-groups list \
  --filter="name=web-api-neg" --format="value(selfLink)"
# add to terraform.tfvars, then
terraform -chdir=terraform/envs/prod apply
```

Everything else is declared in Git and ArgoCD reconciles it.

**During this window**, requests already published are safe in Pub/Sub and drain once
workers return. Users are signed out only if Memorystore was also lost.

## Scenario 2: data corruption or accidental deletion

The one that needs care. Cloud SQL PITR restores to a **new instance** — it cannot restore
in place.

```bash
# 1. STOP THE WRITERS FIRST. Restoring while the worker is still committing gives you a
#    restore that is already stale.
kubectl scale rollout worker  -n sequifi --replicas=0
kubectl scale rollout web-api -n sequifi --replicas=0

# 2. Identify the moment before the damage. The audit trail is the best source.
#    Run against the affected tenant's schema:
#      SELECT created_at, actor_email, action, request_id
#      FROM audit_logs ORDER BY id DESC LIMIT 50;

# 3. Restore to a new instance
gcloud sql instances clone sequifi-prod-mysql sequifi-prod-mysql-restored \
  --point-in-time='2026-09-14T09:15:00Z'

# 4. Verify BEFORE cutting over. Check the tenant that reported the problem.
gcloud sql connect sequifi-prod-mysql-restored --user=app

# 5. Cut over by pointing the proxy at the restored instance
kubectl -n sequifi patch cm app-config --type merge \
  -p '{"data":{"CLOUDSQL_INSTANCE":"PROJECT:us-central1:sequifi-prod-mysql-restored"}}'
kubectl -n sequifi patch cm worker-config --type merge \
  -p '{"data":{"CLOUDSQL_INSTANCE":"PROJECT:us-central1:sequifi-prod-mysql-restored"}}'

# 6. Bring the tiers back
kubectl scale rollout web-api -n sequifi --replicas=3
kubectl scale rollout worker  -n sequifi --replicas=3
```

Then commit the instance name change to Git — otherwise ArgoCD `selfHeal` reverts your
patch within minutes and points production back at the damaged instance. **This is the step
most likely to be forgotten under pressure.**

### Partial recovery: one tenant only

Because tenants are separate schemas, a single tenant can be restored without touching the
others:

```bash
gcloud sql export sql sequifi-prod-mysql-restored \
  gs://BUCKET/restore/tenant_acme.sql --database=tenant_acme

gcloud sql import sql sequifi-prod-mysql \
  gs://BUCKET/restore/tenant_acme.sql --database=tenant_acme_restored
```

Import to a *new* schema name and reconcile deliberately. Importing over a live schema
while other tenants are serving is how a one-tenant incident becomes an all-tenant one.

## Scenario 3: Memorystore loss

No recovery procedure, by design — but understand the consequences:

- **Sessions**: every user is signed out. Annoying, not damaging.
- **Cache**: repopulates on demand.
- **Idempotency claims**: this is the real one. A client whose retry arrives after the loss
  is treated as a new operation, so a payroll run **can** be duplicated.

After a Memorystore incident:

```sql
-- Duplicate payroll runs for the same period
SELECT period_start, period_end, COUNT(*) AS runs,
       GROUP_CONCAT(request_id), GROUP_CONCAT(requested_by_email)
FROM payroll_runs
WHERE created_at > NOW() - INTERVAL 24 HOUR
GROUP BY period_start, period_end
HAVING runs > 1;
```

Run it against every tenant schema. Duplicates need a business decision, not a technical
one — do not delete rows without sign-off.

## Scenario 4: region loss

Not covered by this design, and worth stating plainly. Cloud SQL is regional (multi-zone),
Memorystore is regional, the GKE cluster is regional. A region loss is an outage until the
region returns.

Cross-region would need: a Cloud SQL cross-region replica, a second cluster, and a
global load balancer already fronting both. That is a significant cost increase and a
deliberate decision, not an oversight.

## Testing this

Untested recovery is a hypothesis. Quarterly, in a non-production project:

1. Clone the production instance to a point in time.
2. Point a dev cluster at the clone.
3. Run `./scripts/smoke.sh` against it.
4. Record how long steps 1–3 actually took and update the RTO above with the real number.

The most common finding is a step that assumes knowledge the person on call does not have.
Fix the runbook, not the person.
