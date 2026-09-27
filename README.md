# Multi-Tenant Payroll Platform — React + Laravel + Go on GKE

A multi-tenant SaaS platform built the way the architecture diagram describes: a static
**React 19** SPA on Cloud CDN, a stateless **PHP Laravel** API, **Google Cloud Pub/Sub**
decoupling the expensive work, and a **Go worker pool** that does the calculation and
writes to **Cloud SQL for MySQL** — one schema per tenant.

Everything is here: application code, tests, Terraform, GitOps, progressive delivery,
observability, alerting and runbooks.

```
acme.sequifi.com ─┐
whiteknight...  ─┼─> Cloud Armor + External HTTPS LB ──┬── /*      ─> GCS + Cloud CDN
frdm...         ─┘                                     │              (React SPA, no pods)
                                                       └── /api/*  ─> pod NEG
                                                                        │
                    ┌───────────────────────────────────────────────────┘
                    ▼
          ┌─────────────────────┐
          │  web-api pod        │  nginx ─> php-fpm (Laravel)
          │  + cloud-sql-proxy  │  tenant from Host header, session from Memorystore
          └──────┬───────┬──────┘
    202 Accepted │       │ sync reads
                 ▼       ▼
          Pub/Sub     Memorystore        Firestore
    payroll-calc-events  sessions,       request statuses
          sales-import   cache,          (partitioned by tenant)
                 │       idempotency
                 ▼
          ┌─────────────────────┐
          │  worker pod (Go)    │  pull subscriptions, one goroutine per message
          │  + cloud-sql-proxy  │  payroll engine + sales importer
          └──────────┬──────────┘
                     ▼
        Cloud SQL for MySQL (regional HA, multi-database)
    tenant_acme │ tenant_whiteknight │ tenant_frdm
```

---

## Run it locally

One command. Needs Docker with Compose v2.

```bash
make up            # or  .\dev.ps1 up   on Windows
```

Then open **http://acme.localhost:8080** and sign in.

| Login | Role | Can |
|---|---|---|
| `owner@acme.test` | owner | everything, including managing users |
| `admin@acme.test` | admin | run payroll, import sales, see compensation |
| `operator@acme.test` | operator | import sales, but **not** run payroll |
| `viewer@acme.test` | viewer | read only, no compensation figures |

Password for all: `password`. Other tenants: `whiteknight.localhost:8080`,
`frdm.localhost:8080`.

Not `localhost:8080` — the tenant comes from the subdomain, exactly as in production.
Browsers resolve `*.localhost` to 127.0.0.1 with no hosts-file entry.

```bash
make test          # Go + PHP + frontend
make smoke         # exercise the running stack end to end
make logs
make scale-workers N=3
make clean
```

The local nginx serves the SPA from disk and proxies `/api` to php-fpm, standing in for the
load balancer's URL map. That keeps development **same-origin**, so session cookies behave
exactly as they will in production and there is no CORS configuration anywhere in this
project.

<details>
<summary>Without Docker</summary>

```powershell
cd web-api
composer install
. .\dev-sqlite.ps1          # SQLite per tenant, no GCP, no Redis
php artisan tenants:migrate --seed --create-schema=0
php artisan serve --port=8099

cd ../frontend && npm install && npm run dev    # Vite proxies to :8099
```
</details>

---

## Deploy to GKE

```bash
# 1. Terraform state bucket (once per project)
terraform -chdir=terraform/bootstrap-state init
terraform -chdir=terraform/bootstrap-state apply -var project_id=$PROJECT_ID

# 2. Infrastructure
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars      # fill in
terraform init -backend-config="bucket=$PROJECT_ID-sequifi-tfstate"
terraform apply

# 3. Cluster: addons, secrets, ArgoCD, first sync
cd ../../.. && PROJECT_ID=$PROJECT_ID ENVIRONMENT=prod ./bootstrap/run-all.sh

# 4. Attach the NEGs and re-apply, then DNS and the SPA
```

Full sequence, and why the order is what it is: **[bootstrap/README.md](bootstrap/README.md)**.

After bootstrap nothing is applied by hand. CI pushes an image and commits a tag change;
ArgoCD rolls it out.

---

## Layout

```
frontend/          React 19 + Vite + TS. Static tier, zero pods.
web-api/           PHP 8.2 / Laravel. Tenancy, auth, authz, audit, Pub/Sub publish.
worker-go/         Go 1.24. Payroll engine, sales importer, per-tenant DB pools.

terraform/
  modules/         network, gke, cloudsql, data, iam, edge, monitoring
  stack/           the environment blueprint, instantiated per env
  envs/dev|prod/   thin wrappers; only inputs differ
  bootstrap-state/ the GCS state bucket (local state, the one chicken-and-egg)

gitops/
  argocd/          projects + app-of-apps
  platform/        cluster addons, Prometheus values, alert rules, dashboards
  apps/            Kustomize bases + dev/prod overlays (Argo Rollouts, HPAs, NetworkPolicies)

bootstrap/         ordered, idempotent cluster bootstrap
docs/runbook/      one page per alert
.github/workflows/ CI (test, build, scan, promote to dev) + release (approval-gated prod)
```

---

## The four request types

| # | Request | Behaviour |
|---|---|---|
| 1 | `POST /api/v1/payroll/calculations` | **async** → `payroll-calc-events`, returns `202` |
| 2 | `POST /api/v1/sales/imports` | **async** → `sales-import`, returns `202` |
| 3 | `GET /api/v1/requests/{id}` | **sync** → Firestore status document |
| 4 | `GET /api/v1/employees` | **sync** → Cloud SQL, cached in Memorystore |

Plus reads for committed worker output, the audit trail, auth, and probes — 16 API
endpoints and 3 on the worker. The worker exposes **no business API**: it is fed by two
Pub/Sub subscriptions.

Both writes require an `Idempotency-Key`. A retry replays the original `202` rather than
queueing a second payroll run.

---

## Design decisions worth knowing

### Tenancy is enforced three times, and one of them is explicit

1. **Host header only.** `TenantManager` resolves from the Host header. The `X-Tenant`
   header is honoured only when `tenancy.trust_header` is on, and it is force-disabled when
   `APP_ENV=production` regardless of config.
2. **Session binding.** The tenant is stamped into the session at login and verified on
   every request. Cookie scoping (host-only, named per tenant) normally makes a
   cross-tenant session impossible, but that protection is *implicit* — one config change
   would remove it silently. `EnsureSessionTenant` makes it a check.
3. **The worker re-resolves.** An event carries a tenant *id*; the worker looks the schema
   up in its own registry and ignores the `database` field on the message. A forged event
   cannot redirect a write.

Why this is not paranoia: user ids are per-schema autoincrements, so user `1` is a
different real person in every tenant. `TenancyIsolationTest` fails if any of it regresses.

### Authorization is a matrix, not a boolean

Four roles (`owner`/`admin`/`operator`/`viewer`) mapped to named abilities in
`app/Auth/Role.php`. Routes declare `can:payroll.run`, so the required permission is visible
in `artisan route:list` and a new route cannot ship with no check.

`employees.view` and `employees.view-compensation` are separate: "who works here" and "what
they are paid" are different sensitivities. The compensation flag is part of the **cache
key** — otherwise an admin's cached response would be served to an operator for 60 seconds.

### Money is integer cents

`handler.Money` does all payroll arithmetic in minor units. `ParseMoney` reads the decimal
string digit by digit rather than through `ParseFloat`, because float64 cannot represent
most decimal fractions — `1.005` becomes `1.00499999999999989` and rounds to 100 cents
instead of 101. Run totals are accumulated from rounded line values, never computed
independently, so a run always equals the sum of its lines.

### At-least-once delivery is handled explicitly

Each handler claims `processed_events.event_id` **inside the same transaction** as its
writes. A duplicate hits the unique key, the transaction rolls back, and the message is
acked without repeating the work. There is no window where an event looks processed but its
rows are missing.

Retryable and permanent failures are separated: a bad payload is a `PermanentError` that
marks the request `FAILED` and acks, rather than burning five retries on something that
cannot succeed.

### The worker scales on queue depth

CPU is a lagging signal for a queue consumer — by the time it rises the backlog is already
deep. The HPA reads `num_undelivered_messages` (target ~10 per pod). If the metrics adapter
is down the HPA is *blind* and sits at `minReplicas`, which is why that is step 2 of the
queue runbook.

### Per-tenant connection pools are LRU-bounded

The worker holds a pool per tenant schema. Unbounded, that is `pods × tenants × conns` —
tens of thousands of connections against an instance allowing a few thousand, and
exhaustion fails *every* tenant at once. `DB_MAX_OPEN_SCHEMAS` caps open pools and evicts
the least recently used. Eviction costs a reconnect; exhaustion costs an outage.

### The edge is not a GKE Ingress

The SPA and the API share one hostname so cookies can stay `HttpOnly` + `SameSite=Lax` with
no CORS. The GKE Ingress controller cannot express that — it only creates Service backends,
never a Cloud Storage backend bucket. So the load balancer is Terraform-managed and the
cluster exposes a **standalone NEG** that Terraform attaches. The cost is that Terraform
runs twice; see [bootstrap/README.md](bootstrap/README.md).

### Progressive delivery, with real gates

Workloads are Argo `Rollout`s. The web tier canaries 5% → 25% → 50% (manual gate) → 100%,
with continuous analysis on success rate and p95 latency that aborts on its own.

The worker's analysis is different because it takes no traffic: it measures whether the new
revision *completes work*. A revision that starts, passes its probes and then fails every
message it leases would sail through any request-based check.

### Logs carry severity, and traces span services

Both services emit the field names Cloud Logging actually promotes (`severity`, `message`,
`logging.googleapis.com/trace`). Monolog's stock formatter writes `level_name` and slog
writes `level` — both ignored, which means every line including fatals lands at DEFAULT
severity and no severity-based alert can fire. The trace id propagates onto the Pub/Sub
envelope, so one query spans the HTTP request and the worker's execution of the job.

### Alerts route by consequence

PagerDuty for anything a human must act on now; Slack for everything else. Every alert links
to a runbook page. Cloud Monitoring owns the paging policies deliberately — if the cluster
is the thing that is broken, in-cluster Alertmanager cannot tell anyone.

---

## Verification

```bash
make test     # 37 PHP tests, Go unit tests, frontend typecheck + build
make lint     # gofmt, go vet, YAML + JSON validation
make smoke    # end-to-end against a running stack
```

What is covered:

- **Tenancy isolation** — including a test that fails if the `X-Tenant` override or the
  session binding regresses
- **Authorization** — the full role matrix, plus the compensation cache-key leak
- **Idempotency** — replay, payload-mismatch conflict, per-tenant key scoping
- **Audit trail** — attribution, failed-login recording, per-tenant isolation
- **Payroll arithmetic** — rounding, commission taxation, and the invariant that run totals
  equal the sum of their lines
- **The envelope contract** — real captured envelopes decoded by the Go structs
- **Log severity mapping** — the bug above, guarded

---

## Known limitations

Stated plainly rather than discovered later.

- **Never deployed to a real GKE cluster.** Terraform validates and Kustomize renders, but
  no `apply` has run against GCP. The NEG ordering in particular is reasoned about, not
  observed.
- **Docker was unavailable in the environment this was built in**, so images were never
  built and `docker compose up` was never executed. Dockerfiles and compose config are
  unverified by build.
- **Laravel 9 is end of life** with 4 advisories that have no fix inside `^9.0`. The
  diagram specifies Laravel 9, so that is what is pinned; every other dependency is on a
  patched release. Upgrading touches `app/Http/Kernel.php` and the providers only.
- **Twelve runbook pages are outlines**, tracked in
  [docs/runbook/_remaining.md](docs/runbook/_remaining.md). The alerts carry their triage
  steps inline, so nobody is paged into a blank page.
- **`setWeight` is approximated by pod count.** Without a service mesh, Argo Rollouts
  cannot program the GCP load balancer's backend weights, so 5% weight means roughly 5% of
  pods. Good enough for analysis; exact weights need a mesh or the Gateway API.
- **No cross-region DR.** Cloud SQL, Memorystore and the cluster are all regional. A region
  loss is an outage. Making it otherwise is a significant cost decision, not an oversight —
  see [docs/runbook/disaster-recovery.md](docs/runbook/disaster-recovery.md).
- **The tenant registry is duplicated** across Terraform, the ConfigMap and both services'
  built-in defaults. The ConfigMap is authoritative; the worker logs a warning when an
  event's schema disagrees with its registry.
- **No load testing.** The connection-budget arithmetic and HPA targets are reasoned from
  first principles, not measured.

---

## Documentation

| | |
|---|---|
| [bootstrap/README.md](bootstrap/README.md) | Deployment sequence and why the order matters |
| [docs/runbook/](docs/runbook/README.md) | One page per alert, plus DR |
| [docs/tenant-onboarding.md](docs/tenant-onboarding.md) | Adding a tenant, and what it costs |
| [frontend/README.md](frontend/README.md) | The async job pattern |
| [web-api/README.md](web-api/README.md) | Tenancy, auth and driver switches |
| [worker-go/README.md](worker-go/README.md) | Message lifecycle and tuning |
