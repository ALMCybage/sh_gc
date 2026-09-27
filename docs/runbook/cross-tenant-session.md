# PAGE: Cross-tenant session attempt

**Severity: critical. Treat as a security incident until proven otherwise.**

## What has happened

A session belonging to one tenant was presented to a different tenant's hostname.
`EnsureSessionTenant` rejected it and destroyed the session, so **no data crossed** — but
this should be impossible in normal operation.

Why it matters more than it looks: user ids are per-schema autoincrements. User `1` exists
in every tenant schema and is a *different real person* in each. An accepted cross-tenant
session is not a data leak, it is acting as somebody else entirely.

## Two possible explanations, both urgent

### An attack

Someone is deliberately replaying a session cookie across tenant hostnames.

### A regression in the tenancy controls

The everyday protection is implicit: session cookies are host-only (`SESSION_DOMAIN`
unset) and named per tenant (`sequifi_<tenant>_session`), so acme's cookie is never *sent*
to whiteknight. `EnsureSessionTenant` is the explicit backstop.

If the implicit layer has been switched off, this alert is the only thing standing between
tenants. Check that first.

## Triage

### 1. Read the rejection

```bash
gcloud logging read \
  'jsonPayload.message=~"Session/tenant mismatch"' \
  --limit=50 --freshness=1h \
  --format='table(timestamp, jsonPayload.session_tenant, jsonPayload.request_tenant, jsonPayload.ip, jsonPayload.path)'
```

- **One IP, repeated** → likely an attack or a scanner. Go to §3.
- **Many IPs, or internal addresses** → likely a regression. Go to §2.

### 2. Verify the tenancy controls

```bash
kubectl get cm app-config -n sequifi -o yaml | grep -E 'SESSION_DOMAIN|TENANCY_TRUST_HEADER|SANCTUM_STATEFUL'
```

Required state:

| Setting | Must be | If wrong |
|---|---|---|
| `SESSION_DOMAIN` | absent or empty | `.sequifi.com` makes cookies shared across every tenant hostname |
| `TENANCY_TRUST_HEADER` | `false` | `true` lets a client aim a request at another tenant (production force-disables it, but fix the config anyway) |
| `APP_ENV` | `production` | anything else re-enables the header override |

Also confirm the per-tenant cookie name is still applied:

```bash
curl -sI https://acme.sequifi.com/api/v1/whoami | grep -i set-cookie
# expect: sequifi_acme_session=...
```

A generic `laravel_session` here means `TenantManager::configureSession` is no longer
running before `StartSession` — which would be a middleware-ordering regression in
`app/Http/Kernel.php`. That is a **stop-the-line** finding: fix and deploy immediately.

Regression test that covers exactly this:

```bash
cd web-api && vendor/bin/phpunit --filter=TenancyIsolationTest
```

### 3. If it is an attack

```bash
# The offending source
gcloud logging read 'jsonPayload.message=~"Session/tenant mismatch"' \
  --limit=200 --freshness=6h --format='value(jsonPayload.ip)' | sort | uniq -c | sort -rn

# Block at the edge, before it reaches a pod
gcloud compute security-policies rules create 500 \
  --security-policy=sequifi-prod-armor \
  --src-ip-ranges="<ip>/32" \
  --action=deny-403 \
  --description="Blocked: cross-tenant session attempts, incident <id>"
```

Then determine how they obtained a valid session for either tenant:

```bash
# Successful logins from that address
gcloud logging read \
  'jsonPayload.action="auth.login.succeeded" AND jsonPayload.ip="<ip>"' \
  --limit=50 --freshness=7d
```

If a real account was used, the account is compromised: deactivate it
(`is_active = false` revokes every ability immediately via `Gate::before`, without waiting
for the session to expire) and force a password reset.

### 4. Confirm nothing crossed

The middleware rejects before the auth guard, so a successful cross-tenant read should be
impossible. Verify rather than assume — check the audit trail of the *target* tenant for
activity attributed to an unexpected actor:

```sql
SELECT created_at, actor_email, actor_role, action, ip, outcome
FROM audit_logs
WHERE created_at > NOW() - INTERVAL 24 HOUR
ORDER BY id DESC;
```

Run it against the schema of the tenant named in `request_tenant`.

## After the incident

- Record the window and the conclusion. "No data crossed, here is why" is the answer an
  auditor will want.
- If it was a regression, add a test that fails on it. `TenancyIsolationTest` already
  covers the header override and session replay; extend it rather than relying on this
  runbook.
- If configuration drift caused it, ask why ArgoCD `selfHeal` did not revert it — drift in
  a ConfigMap should not survive.
