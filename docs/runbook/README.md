# Runbook

Every alert in this platform links to a page here. An alert without a runbook is a
puzzle handed to someone who has just been woken up.

## Index

| Alert | Severity | Page |
|---|---|---|
| Dead-letter queue is not empty | PAGE | [dlq-not-empty.md](dlq-not-empty.md) |
| Work queue is not draining | PAGE | [queue-not-draining.md](queue-not-draining.md) |
| Cross-tenant session attempt | PAGE | [cross-tenant-session.md](cross-tenant-session.md) |
| API 5xx above SLO / error budget burning | PAGE | [api-error-rate.md](api-error-rate.md) |
| Cloud SQL unavailable | PAGE | [cloudsql-down.md](cloudsql-down.md) |
| API unreachable from the internet | PAGE | [api-unreachable.md](api-unreachable.md) |
| No worker pods reporting | PAGE | [worker-pool-down.md](worker-pool-down.md) |
| Cloud SQL connections high | WARN | [cloudsql-connections.md](cloudsql-connections.md) |
| Audit writes failing | WARN | [audit-write-failed.md](audit-write-failed.md) |
| Worker permanent failures | WARN | [worker-permanent-failures.md](worker-permanent-failures.md) |
| Worker pool thrashing | WARN | [worker-pool-thrashing.md](worker-pool-thrashing.md) |
| Memorystore memory high | WARN | [redis-memory.md](redis-memory.md) |
| Rollout aborted | WARN | [rollout-aborted.md](rollout-aborted.md) |
| Disaster recovery | — | [disaster-recovery.md](disaster-recovery.md) |
| Onboarding a tenant | — | [../tenant-onboarding.md](../tenant-onboarding.md) |

## Orientation

Two things about this architecture change how you triage it.

**Accepting work and doing work are separate.** The API returns `202` as soon as it has
published to Pub/Sub. So "the API is healthy" and "payroll is being calculated" are
independent facts, and the failure mode that matters most is the quiet one: everything
green, requests accepted, nothing completing. That is why queue depth and DLQ arrivals
page while a slow endpoint only warns.

**Nothing is lost by default.** Pub/Sub retains messages for 7 days and the worker nacks
what it cannot finish. An outage in the worker tier, Cloud SQL, or the whole cluster
delays work rather than destroying it. Resist the urge to replay messages by hand —
almost always the correct action is to fix the dependency and let the backlog drain.

The two exceptions, where work really is abandoned:

- messages that reach the **dead-letter queue** (retries exhausted)
- requests marked **FAILED** by a `PermanentError`

Both are visible and both are alerted.

## First five commands

```bash
# Are the pods there and ready?
kubectl get pods -n sequifi -o wide

# Which dependency is unhealthy? /readyz names them individually.
kubectl exec -n sequifi deploy/web-api -c nginx -- wget -qO- localhost:8080/readyz

# Is a rollout mid-flight? Two revisions serving complicates every other symptom.
kubectl argo rollouts get rollout web-api -n sequifi
kubectl argo rollouts get rollout worker -n sequifi

# Is work moving?
gcloud pubsub subscriptions describe payroll-calc-events-worker

# Recent errors, with tenant and request id attached.
gcloud logging read \
  'resource.labels.namespace_name="sequifi" AND severity>=ERROR' \
  --limit=50 --format='table(timestamp, jsonPayload.tenant_id, jsonPayload.message)'
```

## Correlating a single request

Every log line carries `trace_id`, and the web tier propagates it onto the Pub/Sub
envelope, so one query spans the HTTP request and the worker's execution of the job it
created:

```bash
gcloud logging read 'jsonPayload.request_id="<uuid>"' --limit=100 --freshness=1d
```

If `trace_id` is populated, Cloud Logging groups them into a single trace automatically —
that is what `logging.googleapis.com/trace` in the log formatters is for.

## Escalation

| Situation | Escalate to |
|---|---|
| Suspected cross-tenant data access | Security lead, immediately. Treat as an incident. |
| Payroll figures look wrong | Stop further runs, page the platform lead. Do not delete rows. |
| Data loss suspected | Platform lead + follow [disaster-recovery.md](disaster-recovery.md). |
| Cloud SQL will not recover | GCP support, P1. |
