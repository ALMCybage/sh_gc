# WARN: Cloud SQL connections high

**Severity: warning, but do not defer it.** The failure it precedes is total.

## Why this warns early

When connections run out, **every tenant fails at once** — including the ones behaving
perfectly. There is no graceful degradation: `Too many connections` is returned to
whoever asks next. So the alert fires at 75% of the limit, not at 95%.

## Why usage grows

Connections scale with **pods × tenants**, not with traffic:

```
worker: replicas × DB_MAX_OPEN_SCHEMAS × DB_MAX_OPEN_CONNS
        20       × 8                   × 4                 = 640

web:    replicas × php-fpm pm.max_children
        30       × 16                        = 480

plus migrations, Query Insights, the read replica     ≈ 1120 of 2000
```

That means it creeps up as the platform grows — more tenants, or a higher HPA ceiling —
rather than spiking with load. Which is why it is usually a capacity-planning alert rather
than an incident.

## Triage

### 1. What is the actual usage?

```bash
gcloud sql operations list --instance=sequifi-prod-mysql --limit=5

gcloud monitoring time-series list \
  --filter='metric.type="cloudsql.googleapis.com/database/mysql/connections"' \
  --format='value(points[0].value.int64Value)' | head -1
```

### 2. Who is holding them?

```sql
SELECT user, host, db, COUNT(*) AS conns, SUM(command = 'Sleep') AS idle
FROM information_schema.processlist
GROUP BY user, host, db
ORDER BY conns DESC;
```

A large `idle` count against many different `db` values is the worker's per-tenant pools
sitting open. That is by design — but the LRU cap may be too generous for the current pod
count.

### 3. Confirm the pod arithmetic

```bash
kubectl get rollout worker web-api -n sequifi -o custom-columns='NAME:.metadata.name,REPLICAS:.status.replicas'
kubectl get cm worker-config -n sequifi -o jsonpath='{.data.DB_MAX_OPEN_SCHEMAS} {.data.DB_MAX_OPEN_CONNS}'
```

## Fixes, cheapest first

### A. Lower `DB_MAX_OPEN_SCHEMAS` on the worker

Costs reconnects, not capacity. Each pod keeps fewer tenant pools open and re-dials when a
tenant it evicted sends work again.

```yaml
# gitops/apps/overlays/prod/kustomization.yaml
- DB_MAX_OPEN_SCHEMAS=4
```

Afterwards, watch for the side effect:

```bash
curl -s localhost:8081/metrics | grep worker_tenant_pool_evictions_total
```

If evictions climb sharply you have traded connection pressure for reconnect latency — see
[worker-pool-thrashing.md](worker-pool-thrashing.md). There is a genuine tension between
these two settings; the cap exists because connection exhaustion is the worse failure.

### B. Lower `DB_MAX_OPEN_CONNS`

Reduces per-tenant concurrency. Safe while each handler is a single transaction, which it
currently is.

### C. Lower the HPA ceiling

If the worker is at `maxReplicas: 20` purely because of a backlog it cannot clear for
another reason, fixing that reason reduces connections too.

### D. Raise the limit (Terraform)

```hcl
# terraform/envs/prod/main.tf
sql_max_connections = 4000
sql_tier            = "db-custom-8-32768"   # max_connections scales with memory
```

`max_connections` is a database flag, so applying it restarts the instance — regional HA
makes that a failover of roughly 60 seconds rather than an outage, but schedule it.

## Do not

**Do not raise `max_connections` without raising the tier.** Each connection consumes
memory; more connections on the same instance trades a clear failure for OOM and an
unplanned failover.

## After the incident

- Add the pod-count arithmetic to your capacity model. This alert should be predicted by
  planning, not discovered by monitoring.
- If tenant count drove it, note the connections-per-tenant figure so onboarding has a
  cost attached.
