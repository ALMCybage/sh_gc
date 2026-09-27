# PAGE: Work queue is not draining

**Severity: critical.** The oldest unacknowledged message has been waiting more than 15
minutes.

## What has happened

Requests are being accepted (the API returns `202` regardless) but not processed. Callers
see requests stuck in `QUEUED`. Nothing is lost — Pub/Sub retains for 7 days — but nothing
is progressing either.

The metric is *oldest message age*, not message count, on purpose: a large backlog
draining quickly is fine, while a small backlog that is not moving means the pool is
wedged.

## Triage, in order of likelihood

### 1. Are there any workers?

```bash
kubectl get pods -n sequifi -l app=worker
kubectl argo rollouts get rollout worker -n sequifi
```

No pods → see [worker-pool-down.md](worker-pool-down.md).
Pods present but not `Ready` → step 3.

### 2. Is the HPA scaling? (the most common non-obvious cause)

```bash
kubectl describe hpa worker -n sequifi
```

Look for `unable to fetch metrics` or `<unknown>` against the external metric.

The worker scales on `pubsub.googleapis.com|subscription|num_undelivered_messages`, which
comes from Cloud Monitoring via the Custom Metrics Stackdriver Adapter. **If the adapter
is down, the HPA cannot see the backlog at all and sits at `minReplicas` while the queue
grows.** The symptom looks like "the worker is slow"; the cause is that the autoscaler is
blind.

```bash
kubectl get pods -n custom-metrics
kubectl logs -n custom-metrics -l k8s-app=custom-metrics-stackdriver-adapter --tail=50

# Can the API serve the metric at all?
kubectl get --raw \
  "/apis/external.metrics.k8s.io/v1beta1/namespaces/sequifi/pubsub.googleapis.com|subscription|num_undelivered_messages" \
  | jq
```

A permission error here means the adapter's Workload Identity annotation is wrong — it
needs `roles/monitoring.viewer`. See
`gitops/platform/custom-metrics-adapter/workload-identity.yaml`.

**Immediate mitigation** while you fix the adapter:

```bash
kubectl scale rollout worker -n sequifi --replicas=15
```

### 3. Can the worker reach its dependencies?

```bash
kubectl exec -n sequifi deploy/worker -- wget -qO- localhost:8081/readyz
```

`/readyz` names `mysql`, `firestore` and `subscriptions` individually.

- `mysql` failing → [cloudsql-down.md](cloudsql-down.md) or
  [cloudsql-connections.md](cloudsql-connections.md)
- `subscriptions: attaching` → the worker cannot establish its pull streams; check IAM
  (`roles/pubsub.subscriber`) on the worker's Google service account

### 4. Is it failing everything it leases?

```bash
kubectl port-forward -n sequifi deploy/worker 8081:8081 &
curl -s localhost:8081/metrics | grep -E 'worker_messages_(completed|failed|permanent)'
```

High `failed` with low `completed` means it is leasing and nacking in a loop — messages
are redelivered forever and the age never drops. Usually Cloud SQL contention or a
dependency timing out. See [worker-high-failure-rate.md](worker-high-failure-rate.md).

### 5. Is one enormous message blocking progress?

A payroll run over 50,000 employees is a single message that legitimately takes minutes.
The worker extends the ack deadline while it works (`PUBSUB_ACK_EXTENSION=5m`), so the
oldest-age metric climbs even though nothing is wrong.

```bash
gcloud logging read \
  'jsonPayload.message="event completed" AND jsonPayload.duration_ms>60000' \
  --limit=10 --freshness=1h
```

If that is the cause, this is a capacity question, not an incident: raise
`PUBSUB_MAX_OUTSTANDING`, or split large payroll runs at the API.

### 6. Pool thrashing

```bash
curl -s localhost:8081/metrics | grep worker_tenant_pool
```

A high `worker_tenant_pool_evictions_total` rate means `DB_MAX_OPEN_SCHEMAS` is too low
for the number of tenants this pod is serving, so nearly every message pays a reconnect.
See [worker-pool-thrashing.md](worker-pool-thrashing.md).

## Recovery

Once the cause is fixed the backlog drains on its own. Watch it:

```bash
watch -n 10 'gcloud pubsub subscriptions describe payroll-calc-events-worker \
  --format="value(name)" && gcloud monitoring time-series list \
  --filter="metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\"" \
  --format="value(points[0].value.int64Value)" 2>/dev/null | head -1'
```

**Do not replay messages by hand.** They are still in the subscription; a manual replay
creates duplicates that the idempotency guard absorbs but which waste capacity you
currently do not have.

## After the incident

- If the adapter was the cause, add an alert on the adapter's own availability. A blind
  autoscaler is a silent single point of failure.
- If it was capacity, revisit `maxReplicas` (currently 20) and the
  `averageValue: 10` target.
- Check whether any request exceeded a tenant-visible expectation and needs a
  communication.
