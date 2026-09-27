# Onboarding a tenant

Adding a tenant touches five places. Four are automated; one is DNS.

## The registry is the source of truth

Everything derives from one Terraform variable:

```hcl
# terraform/envs/prod/terraform.tfvars
tenants = {
  acme        = { name = "Acme Corp",    schema = "tenant_acme" }
  whiteknight = { name = "White Knight", schema = "tenant_whiteknight" }
  frdm        = { name = "FRDM",         schema = "tenant_frdm" }
  newco       = { name = "New Co",       schema = "tenant_newco" }   # <- add
}
```

That entry produces:

- the Cloud SQL schema
- the URL map host rule at the edge
- the certificate SAN (or nothing, if you are on the wildcard)
- the uptime check target, if it is the first tenant

## Steps

### 1. Add the entry and apply

```bash
cd terraform/envs/prod
# edit terraform.tfvars
terraform plan     # expect: 1 google_sql_database, 1 url_map change
terraform apply
```

The schema name is validated: it must match `^[a-z0-9_]+$`, because it is interpolated into
a MySQL DSN and identifiers cannot be bound as query parameters. A hyphen fails the plan
rather than producing a broken DSN at runtime.

### 2. Update the application registry

Both services read `TENANTS_JSON` from their ConfigMap. Terraform generates the value, but
the Kustomize overlay holds the copy that is actually deployed:

```bash
terraform output -raw tenants_json > ../../../gitops/apps/overlays/prod/files/tenants.json
```

Commit it. ArgoCD syncs, the ConfigMap hash changes, and both tiers roll.

**Both must be updated together.** If the API knows a tenant the worker does not, requests
are accepted and then permanently failed by the worker with `unknown tenant` — a confusing
failure that looks like a bug rather than a missing config.

### 3. Migrate the new schema

The PreSync Job runs `tenants:migrate` for every tenant in the registry, so the ArgoCD sync
in step 2 does this automatically. To do it immediately:

```bash
kubectl exec -n sequifi deploy/web-api -c php-fpm -- \
  php artisan tenants:migrate --tenant=newco --force
```

Verify:

```bash
kubectl exec -n sequifi deploy/web-api -c php-fpm -- \
  php artisan tenants:list --check-db
```

### 4. DNS

The only manual step.

```bash
terraform output -json dns_records_required | jq
# newco.sequifi.com  A  34.x.x.x
```

With the wildcard certificate (`use_wildcard_certificate = true`) there is nothing else to
do. Without it, the certificate has to be reissued with the new SAN, which takes 15–60
minutes and is the reason the wildcard is the right choice past a handful of tenants.

### 5. Create the first user

There is no self-service signup. The first user is created deliberately:

```bash
kubectl exec -n sequifi deploy/web-api -c php-fpm -- \
  php artisan tinker --execute='
    app(App\Tenancy\TenantManager::class)->runFor(
      app(App\Tenancy\TenantManager::class)->findOrFail("newco"),
      fn () => App\Models\User::create([
        "name"      => "New Co Owner",
        "email"     => "owner@newco.example.com",
        "password"  => Hash::make(Str::random(24)),
        "role"      => App\Auth\Role::OWNER,
        "is_active" => true,
      ])
    );
  '
```

Then have them reset the password through the normal flow. Note the `owner` role — it is
the only one that can manage other users, so the first user has to hold it.

## Verify

```bash
# Tenant resolves and reports the right schema
curl -s https://newco.sequifi.com/api/v1/whoami | jq

# Full flow, including the async pipeline
./scripts/smoke.sh https://newco.sequifi.com newco
```

## Checklist

- [ ] `tenants` entry added, `terraform apply` clean
- [ ] `tenants.json` regenerated and committed
- [ ] ArgoCD synced; both tiers rolled
- [ ] `tenants:list --check-db` shows `ok`
- [ ] DNS A record resolves to the load balancer
- [ ] Certificate covers the hostname (`ACTIVE`, not `PROVISIONING`)
- [ ] First owner created; password reset sent
- [ ] `smoke.sh` passes against the new hostname
- [ ] Connection budget still has headroom (see [cloudsql-connections.md](runbook/cloudsql-connections.md))

## The cost of a tenant

Worth tracking, because it is not free:

- **Cloud SQL connections**: up to `DB_MAX_OPEN_CONNS` per worker pod that serves them.
  With 20 pods and 4 connections that is 80 in the worst case — which is why
  `DB_MAX_OPEN_SCHEMAS` caps how many schemas one pod holds open at a time.
- **A schema** with its own tables and indexes.
- **A certificate SAN**, unless on the wildcard (100 domain limit).
- **Pub/Sub**: nothing. Tenants share the topics; the tenant id is a message attribute.

Enable `usage_export_dataset` in Terraform for per-namespace cost attribution in BigQuery.

## Offboarding

Deliberately manual. Deleting a tenant's data is irreversible.

1. Export first: `gcloud sql export sql ... --database=tenant_x`
2. Remove the DNS record.
3. Remove from `tenants` and `tenants.json`, commit, apply.
4. The schema is **not** dropped — `deletion_policy = "ABANDON"` on the
   `google_sql_database` resource keeps it. Drop it by hand, after the export is verified
   and the retention period has passed.

The audit trail lives inside the tenant schema, so it goes with the export. Check your
retention obligations before dropping anything.
