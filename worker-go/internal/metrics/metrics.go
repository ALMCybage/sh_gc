// Package metrics exposes worker counters in Prometheus text format.
//
// Hand-rolled rather than pulled from a client library: the worker only needs a
// handful of counters, and this keeps the dependency tree (and therefore the
// image and its CVE surface) small. The Managed Service for Prometheus collector
// scrapes /metrics and the values feed the HPA's external metric.
package metrics

import (
	"fmt"
	"io"
	"sort"
	"sync"
	"sync/atomic"
)

// Registry holds the worker's counters and gauges.
type Registry struct {
	received      atomic.Int64
	completed     atomic.Int64
	failed        atomic.Int64
	permanent     atomic.Int64
	duplicate     atomic.Int64
	inFlight      atomic.Int64
	poolEvictions atomic.Int64
	poolsOpen     atomic.Int64
	poolsCap      atomic.Int64

	mu         sync.Mutex
	byEventOK  map[string]int64
	byEventErr map[string]int64
	latencyMS  map[string]int64
	latencyN   map[string]int64
}

// New creates an empty registry.
func New() *Registry {
	return &Registry{
		byEventOK:  map[string]int64{},
		byEventErr: map[string]int64{},
		latencyMS:  map[string]int64{},
		latencyN:   map[string]int64{},
	}
}

// MessageReceived records a lease.
func (r *Registry) MessageReceived() {
	r.received.Add(1)
	r.inFlight.Add(1)
}

// MessageDone releases the in-flight gauge.
func (r *Registry) MessageDone() { r.inFlight.Add(-1) }

// Completed records a successful handle.
func (r *Registry) Completed(eventType string, durationMS int64) {
	r.completed.Add(1)
	r.mu.Lock()
	r.byEventOK[eventType]++
	r.latencyMS[eventType] += durationMS
	r.latencyN[eventType]++
	r.mu.Unlock()
}

// Failed records a retryable failure.
func (r *Registry) Failed(eventType string) {
	r.failed.Add(1)
	r.mu.Lock()
	r.byEventErr[eventType]++
	r.mu.Unlock()
}

// PermanentFailure records a failure that will not be retried.
func (r *Registry) PermanentFailure(eventType string) {
	r.permanent.Add(1)
	r.mu.Lock()
	r.byEventErr[eventType]++
	r.mu.Unlock()
}

// Duplicate records a redelivery that was skipped by the idempotency guard.
func (r *Registry) Duplicate() { r.duplicate.Add(1) }

// SchemaPoolEvicted records an LRU eviction of a tenant connection pool. A high
// rate here means MaxOpenSchemas is too low for how many tenants this pod serves,
// and every eviction costs a reconnect on the next message for that tenant.
func (r *Registry) SchemaPoolEvicted() { r.poolEvictions.Add(1) }

// SetSchemaPoolGauges publishes the current tenant pool population against its
// cap, so the cap can be tuned from evidence.
func (r *Registry) SetSchemaPoolGauges(open, capacity int) {
	r.poolsOpen.Store(int64(open))
	r.poolsCap.Store(int64(capacity))
}

// InFlight is the current number of leased messages, which is the signal the
// HPA scales on alongside Pub/Sub's undelivered-message count.
func (r *Registry) InFlight() int64 { return r.inFlight.Load() }

// WritePrometheus renders the exposition format.
func (r *Registry) WritePrometheus(w io.Writer) {
	fmt.Fprint(w, "# HELP worker_messages_received_total Pub/Sub messages leased by this pod.\n")
	fmt.Fprint(w, "# TYPE worker_messages_received_total counter\n")
	fmt.Fprintf(w, "worker_messages_received_total %d\n", r.received.Load())

	fmt.Fprint(w, "# HELP worker_messages_completed_total Messages handled successfully.\n")
	fmt.Fprint(w, "# TYPE worker_messages_completed_total counter\n")
	fmt.Fprintf(w, "worker_messages_completed_total %d\n", r.completed.Load())

	fmt.Fprint(w, "# HELP worker_messages_failed_total Messages nacked for retry.\n")
	fmt.Fprint(w, "# TYPE worker_messages_failed_total counter\n")
	fmt.Fprintf(w, "worker_messages_failed_total %d\n", r.failed.Load())

	fmt.Fprint(w, "# HELP worker_messages_permanent_failed_total Messages acked as unprocessable.\n")
	fmt.Fprint(w, "# TYPE worker_messages_permanent_failed_total counter\n")
	fmt.Fprintf(w, "worker_messages_permanent_failed_total %d\n", r.permanent.Load())

	fmt.Fprint(w, "# HELP worker_messages_duplicate_total Redeliveries skipped by the idempotency guard.\n")
	fmt.Fprint(w, "# TYPE worker_messages_duplicate_total counter\n")
	fmt.Fprintf(w, "worker_messages_duplicate_total %d\n", r.duplicate.Load())

	fmt.Fprint(w, "# HELP worker_messages_in_flight Messages currently being processed.\n")
	fmt.Fprint(w, "# TYPE worker_messages_in_flight gauge\n")
	fmt.Fprintf(w, "worker_messages_in_flight %d\n", r.inFlight.Load())

	fmt.Fprint(w, "# HELP worker_tenant_pools_open Tenant schema connection pools currently open on this pod.\n")
	fmt.Fprint(w, "# TYPE worker_tenant_pools_open gauge\n")
	fmt.Fprintf(w, "worker_tenant_pools_open %d\n", r.poolsOpen.Load())

	fmt.Fprint(w, "# HELP worker_tenant_pools_max Configured cap on simultaneously open tenant pools.\n")
	fmt.Fprint(w, "# TYPE worker_tenant_pools_max gauge\n")
	fmt.Fprintf(w, "worker_tenant_pools_max %d\n", r.poolsCap.Load())

	fmt.Fprint(w, "# HELP worker_tenant_pool_evictions_total LRU evictions of tenant connection pools.\n")
	fmt.Fprint(w, "# TYPE worker_tenant_pool_evictions_total counter\n")
	fmt.Fprintf(w, "worker_tenant_pool_evictions_total %d\n", r.poolEvictions.Load())

	r.mu.Lock()
	defer r.mu.Unlock()

	fmt.Fprint(w, "# HELP worker_events_total Handled events by type and outcome.\n")
	fmt.Fprint(w, "# TYPE worker_events_total counter\n")

	for _, eventType := range sortedKeys(r.byEventOK, r.byEventErr) {
		fmt.Fprintf(w, "worker_events_total{event_type=%q,outcome=\"ok\"} %d\n", eventType, r.byEventOK[eventType])
		fmt.Fprintf(w, "worker_events_total{event_type=%q,outcome=\"error\"} %d\n", eventType, r.byEventErr[eventType])
	}

	fmt.Fprint(w, "# HELP worker_event_duration_ms_avg Mean handler duration by event type.\n")
	fmt.Fprint(w, "# TYPE worker_event_duration_ms_avg gauge\n")

	for eventType, n := range r.latencyN {
		if n > 0 {
			fmt.Fprintf(w, "worker_event_duration_ms_avg{event_type=%q} %d\n", eventType, r.latencyMS[eventType]/n)
		}
	}
}

func sortedKeys(maps ...map[string]int64) []string {
	seen := map[string]struct{}{}

	for _, m := range maps {
		for k := range m {
			seen[k] = struct{}{}
		}
	}

	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}

	sort.Strings(out)

	return out
}
