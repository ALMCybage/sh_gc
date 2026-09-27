# PAGE: No worker pods reporting

**Severity: critical.** Work is being accepted and nothing is processing it.

Nothing is lost — Pub/Sub retains for 7 days and unacked messages stay in the
subscription. The urgency is that requests pile up invisibly: the API keeps returning
`202`, so from the outside the platform looks healthy.

## Triage

```bash
kubectl get pods -n sequifi -l app=worker -o wide
kubectl argo rollouts get rollout worker -n sequifi
kubectl get events -n sequifi --sort-by=.lastTimestamp | tail -30
```

| Symptom | Cause | Action |
|---|---|---|
| No pods at all | Rollout scaled to 0, or the Application is out of sync | §A |
| `Pending` | No capacity, or the ResourceQuota is exhausted | §B |
| `CrashLoopBackOff` | Config or dependency failure at startup | §C |
| `ImagePullBackOff` | Tag does not exist in Artifact Registry | §D |
| Running but not `Ready` | Readiness failing | §E |

## §A No pods

```bash
kubectl get application sequifi-prod -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'
kubectl get rollout worker -n sequifi -o jsonpath='{.spec.replicas}'
```

If someone scaled it to zero, ArgoCD `ignoreDifferences` on `/spec/replicas` means it will
**not** self-heal that (the HPA owns replicas). Scale it back:

```bash
kubectl scale rollout worker -n sequifi --replicas=3
```

## §B Pending

```bash
kubectl describe pod -n sequifi -l app=worker | grep -A5 Events
kubectl describe resourcequota sequifi-quota -n sequifi
```

Autopilot provisions capacity on demand, so `Pending` for more than a couple of minutes
usually means the namespace quota is exhausted — often because the web tier scaled up at
the same time. Raise the quota in `gitops/apps/shared/base/namespace.yaml`.

## §C CrashLoopBackOff

```bash
kubectl logs -n sequifi -l app=worker --tail=100 --previous
```

The worker refuses to start on a configuration error rather than running degraded. Common:

- `GOOGLE_CLOUD_PROJECT is required` — ConfigMap missing or misnamed
- `invalid TENANTS_JSON` / `tenant registry is empty` — malformed registry
- `schema name ... contains an unsupported character` — a bad schema name in the registry
- `firestore: ...` — Workload Identity annotation wrong, so it cannot get a token

Check the identity binding:

```bash
kubectl get sa worker -n sequifi -o jsonpath='{.metadata.annotations}'
gcloud iam service-accounts get-iam-policy sequifi-prod-worker@PROJECT.iam.gserviceaccount.com
```

## §D ImagePullBackOff

The tag in the overlay does not exist. Usually a promotion of a tag CI never built.

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/PROJECT/sequifi/worker --include-tags --limit=10
```

Roll back by re-running the release workflow with the previous tag.

## §E Not Ready

```bash
kubectl exec -n sequifi deploy/worker -- wget -qO- localhost:8081/readyz
```

`/readyz` reports `mysql`, `firestore` and `subscriptions` individually:

- `subscriptions: attaching` — cannot establish pull streams; check
  `roles/pubsub.subscriber` and that the subscription exists
- `mysql` — see [cloudsql-down.md](cloudsql-down.md)
- `firestore` — Workload Identity or API enablement

## Recovery

Once pods are Ready the backlog drains on its own. Do not replay messages by hand; they are
still in the subscription.

```bash
kubectl logs -n sequifi -l app=worker -f | grep 'event completed'
```
