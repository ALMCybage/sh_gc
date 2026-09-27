# web-api — Stateless Core Web API (PHP 8.2 / Laravel 9)

Accepts the four inbound request types, publishes the asynchronous ones to Google
Cloud Pub/Sub, and serves synchronous reads from Cloud SQL (via Memorystore) and
Firestore. See the [root README](../README.md) for the full architecture, local
stack and deployment instructions.

## Where things live

| Concern | Path |
|---|---|
| Tenant resolution + schema switching | `app/Tenancy/`, `app/Http/Middleware/ResolveTenant.php` |
| Pub/Sub publishing | `app/Services/PubSub/` |
| Firestore request statuses | `app/Services/Status/` |
| Event contract shared with the Go worker | `app/Services/Messaging/Envelope.php` |
| Async dispatch (202 path) | `app/Services/Messaging/AsyncCommandBus.php` |
| Endpoints | `routes/api.php`, `app/Http/Controllers/Api/` |
| Tenant schema | `database/migrations/tenant/` |
| Container config | `Dockerfile`, `docker/` |

## Useful commands

```bash
php artisan tenants:list --check-db        # registry + per-schema connectivity
php artisan tenants:migrate --seed        # create, migrate and seed every schema
php artisan tenants:migrate --tenant=acme # one tenant only
php artisan route:list
```

## Driver switches

| Variable | Values | Notes |
|---|---|---|
| `PUBSUB_DRIVER` | `rest`, `log` | `rest` uses `PUBSUB_EMULATOR_HOST` when set, otherwise Workload Identity. `log` writes the envelope to the log instead of publishing. |
| `FIRESTORE_DRIVER` | `rest`, `cache`, `null` | `cache` keeps statuses in the Laravel cache for offline dev; the Go worker cannot write there. |
