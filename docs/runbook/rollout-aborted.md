# WARN: Rollout aborted

**Severity: warning.** The system worked as designed — but a deploy did not land.

## What has happened

The canary analysis failed and Argo Rollouts rolled back to the previous revision.
There is no user impact: the stable revision is serving all traffic. What is left is
finding out why the new revision was worse.

Without this alert the failure is silent. The rollback works, the previous revision keeps
serving, and nobody learns the deploy failed until they wonder why their change is not
live.

## Triage

### 1. Which analysis failed, and on what number?

```bash
kubectl argo rollouts get rollout web-api -n sequifi
kubectl get analysisruns -n sequifi --sort-by=.metadata.creationTimestamp | tail -5
kubectl describe analysisrun <name> -n sequifi
```

The `describe` output shows the measured value against the `successCondition`. That number
is the whole story:

| Failed metric | Threshold | Meaning |
|---|---|---|
| `success-rate` | ≥ 0.98 | The canary returned 5xx |
| `p95-latency-ms` | ≤ 1000 | The canary was slow |
| `permanent-failure-rate` (worker) | ≤ 0.05 | The canary rejected work as unprocessable |
| `completion-rate` (worker) | ≥ 0.9 | The canary leased work and did not finish it |

### 2. What did the canary pods actually log?

```bash
# The canary ReplicaSet's hash
HASH=$(kubectl get rollout web-api -n sequifi -o jsonpath='{.status.currentPodHash}')

gcloud logging read \
  "resource.labels.namespace_name=\"sequifi\" AND severity>=ERROR AND labels.\"k8s-pod/rollouts-pod-template-hash\"=\"${HASH}\"" \
  --limit=50 --freshness=1h
```

## Common causes

**A migration that did not run, or is not additive.** During a canary two revisions share
one schema. A revision expecting a column that does not exist fails; a migration that
*dropped* a column breaks the stable revision instead, which is worse. The PreSync Job runs
migrations before the Rollout is touched, so check it succeeded:

```bash
kubectl logs -n sequifi job/tenants-migrate --tail=50
```

**A config value the new revision needs and the ConfigMap lacks.** The web tier's
entrypoint fails deliberately rather than serving broken responses, so this shows as a
startup failure rather than degraded traffic.

**A genuine performance regression.** The latency threshold is generous — async writes
return in ~150ms, so crossing 1000ms at p95 means something real.

**A worker revision that rejects work.** `permanent-failure-rate` catches the case a
request-based check never would: the pods are healthy, probes pass, and every message is
being refused.

**Analysis that could not measure anything.** If Prometheus was unreachable or the canary
received no traffic, the query returns no data and the condition fails. Check:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
```

This is a false negative, not a bad revision. The recording rules use `clamp_min` to avoid
divide-by-zero producing `NaN` for exactly this reason, but an unreachable Prometheus still
fails.

## After you have the cause

Fix forward. Do not retry the same image and hope:

```bash
# Confirm the stable revision is serving everything
kubectl argo rollouts get rollout web-api -n sequifi

# Then commit the fix; CI builds a new tag and ArgoCD picks it up.
```

To retry an identical image after fixing something external (a missed migration, a
ConfigMap value):

```bash
kubectl argo rollouts retry rollout web-api -n sequifi
```

## Emergency: skip the analysis

Only when you know the analysis is wrong, not when you are impatient:

```bash
kubectl argo rollouts promote --full web-api -n sequifi
```

This bypasses every remaining step and gate. Record why in the incident notes — a
`--full` promote is how a bad revision reaches 100% of traffic.
