# WARN: Audit writes are failing

**Severity: warning by impact, compliance issue by consequence.**

## What has happened

`AuditLogger` could not write to `audit_logs`. Requests still succeed — the logger
deliberately swallows its own errors so a compliance problem cannot become an availability
one.

That design choice has a direct consequence: **this alert is the only signal that the
audit trail is incomplete.** Nothing else will tell you. A silently missing trail is worse
than a failed request, which is why the failure is logged loudly even though it is
suppressed.

## Triage

### 1. Why is it failing?

```bash
gcloud logging read 'jsonPayload.message="AUDIT WRITE FAILED"' \
  --limit=20 --freshness=1h \
  --format='table(timestamp, jsonPayload.tenant_id, jsonPayload.action, jsonPayload.error)'
```

### 2. Match the error

| Error contains | Cause | Fix |
|---|---|---|
| `no such table: audit_logs` / `Table ... doesn't exist` | A tenant schema was not migrated | §A |
| `Unknown column` | Schema drift between revisions | §A |
| `Too many connections` | Connection exhaustion | [cloudsql-connections.md](cloudsql-connections.md) |
| `Duplicate entry` | Should be impossible — the table is append-only with no unique keys | §C |
| `Data too long` | An oversized `user_agent` or `context` | §B |

## §A — Schema drift or a missed migration

The most common cause. A tenant was onboarded without running migrations, or the migration
Job failed for one schema and succeeded for the others.

```bash
# Did the PreSync Job succeed for every tenant?
kubectl logs -n sequifi job/tenants-migrate --tail=100

# Which tenants have the table?
kubectl exec -n sequifi deploy/web-api -c php-fpm -- \
  php artisan tenants:list --check-db
```

Fix:

```bash
kubectl create job --from=cronjob/tenants-migrate tenants-migrate-manual -n sequifi
# or, for one tenant
kubectl exec -n sequifi deploy/web-api -c php-fpm -- \
  php artisan tenants:migrate --tenant=<id> --force
```

This is exactly why migrations must be **additive**. During a canary, two revisions run
against one schema; a migration that drops or renames a column breaks the revision still
serving most of the traffic.

## §B — Oversized field

`AuditLogger` already truncates `user_agent` to 250 characters. If `context` is too large,
something is putting more than parameters in it — the design records *parameters, never
payloads*, because the rows themselves live in `sales_records` and would bloat the trail.

Find the offending call site and reduce what it passes.

## §C — Unexpected

`audit_logs` is append-only with an autoincrement id and no unique constraint, so a
duplicate-key error means the schema has been altered. Compare against
`database/migrations/tenant/2024_01_01_000600_create_audit_logs_table.php`.

## Assessing the gap

Once writes are working again, establish what was not recorded. Actions in the gap window
are unattributable, and an auditor will ask.

```sql
-- Gaps in the trail
SELECT
  created_at,
  TIMESTAMPDIFF(MINUTE, LAG(created_at) OVER (ORDER BY created_at), created_at) AS gap_minutes
FROM audit_logs
WHERE created_at > NOW() - INTERVAL 24 HOUR
ORDER BY created_at;
```

Cross-check against work that definitely happened, because `payroll_runs` carries its own
attribution (`requested_by_email`) written by the worker:

```sql
SELECT p.request_id, p.requested_by_email, p.created_at
FROM payroll_runs p
LEFT JOIN audit_logs a ON a.request_id = p.request_id
WHERE p.created_at > NOW() - INTERVAL 24 HOUR
  AND a.id IS NULL;
```

Anything returned by that query is a payroll run with no audit entry — recoverable
attribution, because the denormalised column on `payroll_runs` exists precisely for this.
Record the reconstruction in the incident notes.

## After the incident

- Note the window and the reconstruction in the incident record.
- If a missed migration caused it, the PreSync Job should have caught it — find out why it
  reported success.
- Consider whether audit writes should be retried once before being swallowed. The current
  behaviour is a deliberate availability choice, but a single retry would cost little.
