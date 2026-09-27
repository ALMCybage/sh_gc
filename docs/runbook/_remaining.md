# Runbook pages not yet written

Being explicit about this rather than leaving dead links from the alert policies.

The alerts below fire and route correctly, and their Cloud Monitoring `documentation`
blocks (in `terraform/modules/monitoring/main.tf`) carry the triage steps inline — so
someone paged is not left with nothing. But they do not have a full page here yet.

| Alert | Runbook link in the alert | Interim guidance |
|---|---|---|
| `api-error-rate` | `docs/runbook/api-error-rate.md` | Alert documentation + [rollout-aborted.md](rollout-aborted.md) |
| `cloudsql-down` | `docs/runbook/cloudsql-down.md` | Alert documentation. Regional HA fails over in ~60s; if it has not, check the operations log |
| `api-unreachable` | `docs/runbook/api-unreachable.md` | Almost always empty NEGs — see the ordering note in [../../bootstrap/README.md](../../bootstrap/README.md) |
| `slo-burn-rate` | `docs/runbook/slo-burn-rate.md` | Same triage as `api-error-rate` |
| `redis-memory` | `docs/runbook/redis-memory.md` | Alert documentation. Note the idempotency-claim consequence in [disaster-recovery.md](disaster-recovery.md#scenario-3-memorystore-loss) |
| `worker-high-failure-rate` | `docs/runbook/worker-high-failure-rate.md` | Start at [queue-not-draining.md](queue-not-draining.md) step 4 |
| `worker-permanent-failures` | `docs/runbook/worker-permanent-failures.md` | Same classification as [dlq-not-empty.md](dlq-not-empty.md) §A |
| `worker-pool-thrashing` | `docs/runbook/worker-pool-thrashing.md` | Trade-off explained in [cloudsql-connections.md](cloudsql-connections.md) fix A |
| `worker-duplicates` | `docs/runbook/worker-duplicates.md` | Usually the ack deadline being exceeded; raise `PUBSUB_ACK_EXTENSION` |
| `crash-looping` | `docs/runbook/crash-looping.md` | [worker-pool-down.md](worker-pool-down.md) §C applies to both tiers |
| `web-pods-unavailable` | `docs/runbook/web-pods-unavailable.md` | Check `/readyz` first; it names the failing dependency |
| `rollout-paused` | `docs/runbook/rollout-paused.md` | `kubectl argo rollouts promote web-api -n sequifi` |

## Writing one

The pages that exist follow a shape that works under pressure:

1. **What has happened** — plain language, and whether data is at risk
2. **Why it matters** — the non-obvious consequence, if there is one
3. **Triage** — ordered by likelihood, with the exact command to run
4. **Fixes** — cheapest and least risky first
5. **Do not** — the tempting action that makes it worse
6. **After the incident** — what should change so this does not recur

The most valuable section is usually (5). Most of the damage in an incident comes from a
reasonable-looking action taken quickly — replaying Pub/Sub messages that are still in the
subscription, importing a restore over a live schema, raising `max_connections` without
raising the tier.
