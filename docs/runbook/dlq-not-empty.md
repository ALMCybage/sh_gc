# PAGE: Dead-letter queue is not empty

**Severity: critical.** Work has been abandoned and nobody has been told.

## What has happened

A message failed `max_delivery_attempts` (5) times and Pub/Sub moved it to
`worker-dead-letter`. That means:

- a tenant's payroll run or sales import **will never complete**
- the caller's request is stuck in `PROCESSING` or was marked `FAILED`
- nothing else will retry it

This is the failure mode this architecture is most prone to, and the reason it pages:
nothing errors at the edge, the API returned `202` as usual, and a tenant simply never
gets their payroll. Without this alert it would surface as a support ticket days later.

## Triage

### 1. Read a message without consuming it

```bash
gcloud pubsub subscriptions pull worker-dead-letter-inspect \
  --limit=5 --format=json | jq -r '.[].message.data' | base64 -d | jq
```

`--limit` without `--auto-ack` leaves the message in place. Do not ack until you have
decided what to do with it.

From the envelope, note `tenant_id`, `request_id`, `event_type` and `actor.email`.

### 2. Find out why the worker refused it

```bash
gcloud logging read \
  'jsonPayload.request_id="<request_id>" AND severity>=WARNING' \
  --limit=20 --freshness=7d --format='value(jsonPayload.message, jsonPayload.error)'
```

### 3. Classify it

| Log line | Meaning | Action |
|---|---|---|
| `permanent failure, acking` | Bad payload, unknown tenant, FK violation | §A |
| `retry budget exhausted` | Transient fault that never cleared | §B |
| `dropping unparseable message` | Malformed body; already acked, should not be here | §C |
| `unsupported schema_version` | Producer/consumer version skew | §D |

## §A — Permanent failure

The worker was right to refuse it. Something upstream produced work it cannot do.

```bash
# What did the API accept that the worker rejected?
gcloud logging read 'jsonPayload.request_id="<request_id>"' --limit=50 --freshness=7d
```

Common causes and fixes:

- **Unknown tenant** — the tenant is in the API's registry but not the worker's. Both
  read `TENANTS_JSON` from their ConfigMap; check they match, and that the tenant's
  schema was migrated.
- **Missing employee** (FK violation) — a sales row references a rep who has since been
  deleted. Fix the data, then ask the tenant to resubmit.
- **Payload the API accepted but the worker rejects** — this is a validation gap. Add the
  rule to the Laravel FormRequest so the caller gets a `422` instead of a silent failure
  hours later. That is the real fix; resubmitting is only the immediate remedy.

Then: ack the dead-lettered message and have the tenant resubmit. Resubmission is safe —
the `Idempotency-Key` contract means a genuine duplicate replays rather than queueing a
second run.

## §B — Retries exhausted

The dependency was down for longer than five attempts with 10s→600s backoff, so roughly
half an hour or more.

1. Confirm the dependency is healthy now (`/readyz` on a worker pod).
2. Republish the message body to the original topic:

```bash
gcloud pubsub topics publish payroll-calc-events \
  --message="$(cat envelope.json)" \
  --attribute="tenant_id=<tenant>,event_type=payroll.calculate.requested,schema_version=2,request_id=<request_id>"
```

The `event_id` is unchanged, so the worker's `processed_events` guard means this is safe
even if a partial commit happened: a duplicate hits the unique key, the transaction rolls
back, and the message is acked without repeating the work.

## §C — Unparseable message

The worker acks these immediately, so it should never reach the DLQ. If one has, some
other producer is publishing to these topics. Check the `source` field on the envelope
and find out what is writing to the topic.

## §D — Schema version skew

`schema_version` is bumped on any breaking envelope change, and the worker refuses a
version it does not know rather than guessing. Seeing this means a web tier and a worker
from different releases are running together.

```bash
kubectl argo rollouts get rollout web-api -n sequifi
kubectl argo rollouts get rollout worker -n sequifi
```

Fix: finish or abort the in-flight rollout so both tiers are on compatible revisions, then
republish. **Deploy order matters** — the consumer has to understand the new version
before the producer starts emitting it.

## After the incident

- Was the tenant told? A `FAILED` request they never polled is invisible to them.
- If this was a validation gap, the fix belongs in the API, not the runbook.
- If retries were exhausted by a long outage, consider whether
  `max_delivery_attempts` should be higher for that flow.
- Confirm the DLQ is back to zero: the alert auto-closes after 24h, which is not the same
  as resolved.
