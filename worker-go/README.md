# worker-go — Calculation Engine Worker Pool (Go 1.24)

Pulls from two Pub/Sub subscriptions, runs the work with one goroutine per
message, and commits results to the calling tenant's MySQL schema. Takes no
inbound application traffic. See the [root README](../README.md) for the full
architecture.

## Flow per message

```
decode envelope ─> resolve tenant in local registry ─> get schema pool
   └─> status: PROCESSING (Firestore)
        └─> BEGIN
              claim processed_events.event_id     (idempotency, same tx)
              run handler (payroll | sales)
            COMMIT
             └─> status: COMPLETED + summary, ack
```

Outcomes:

| Result | Action |
|---|---|
| success | status `COMPLETED`, `Ack` |
| duplicate `event_id` | `Ack`, no work repeated |
| `PermanentError` (bad payload, unknown tenant, FK violation) | status `FAILED`, `Ack` |
| transient (Cloud SQL down, deadlock) | `Nack` for redelivery |
| retries exhausted (`WORKER_MAX_RETRIES`) | status `FAILED`, `Ack` |

## Build and run

```bash
go build ./...
go vet ./...

GOOGLE_CLOUD_PROJECT=local-dev \
PUBSUB_EMULATOR_HOST=localhost:8085 \
FIRESTORE_EMULATOR_HOST=localhost:8086 \
DB_HOST=127.0.0.1 DB_USERNAME=app DB_PASSWORD=secret \
go run ./cmd/worker
```

## Configuration

Everything comes from the environment (`internal/config/config.go`). The ones that
change behaviour most:

| Variable | Default | Notes |
|---|---|---|
| `PUBSUB_MAX_OUTSTANDING` | `20` | Messages leased per pod. The backpressure lever: lower it and the backlog grows, which is what the HPA scales on. |
| `PUBSUB_NUM_GOROUTINES` | `4` | Concurrent stream pullers. |
| `PUBSUB_ACK_EXTENSION` | `5m` | How long a long payroll run may keep extending its ack deadline. |
| `WORKER_MAX_RETRIES` | `5` | Match the subscription's `--max-delivery-attempts`. |
| `DB_MAX_OPEN_CONNS` | `10` | Per tenant schema. Multiply by active tenants when sizing Cloud SQL `max_connections`. |
| `STATUS_DRIVER` | `firestore` | `none` disables status tracking. |
| `TENANTS_JSON` | built-in | Must match the Laravel app's registry. |

## Endpoints

`:8081/healthz` (liveness, dependency-free), `:8081/readyz` (checks MySQL,
Firestore, subscriptions), `:8081/metrics` (Prometheus text format).
