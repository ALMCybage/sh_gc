// Package broker holds the Pub/Sub wire contract and the subscriber plumbing.
package broker

import (
	"encoding/json"
	"fmt"
	"time"
)

// SchemaVersion must match Envelope::SCHEMA_VERSION in the Laravel app
// (web-api/app/Services/Messaging/Envelope.php). A worker that sees a different
// version refuses the message instead of guessing at its meaning.
//
// v2 added the Actor block. The change is additive, but the version was bumped
// deliberately: a v1 worker would happily process a v2 event and write a payroll
// row with no attribution, and an unattributable payroll run is not an acceptable
// degraded outcome. Better to refuse and dead-letter.
const SchemaVersion = "2"

// Event types published by the web tier.
const (
	EventPayrollCalculateRequested = "payroll.calculate.requested"
	EventSalesImportRequested      = "sales.import.requested"
)

// TenantRef is the tenant context carried on every event. The worker trusts the
// tenant id but re-resolves the schema through its own registry, so a forged or
// stale "database" value can never point a write at the wrong schema.
type TenantRef struct {
	ID       string `json:"id"`
	Database string `json:"database"`
	Currency string `json:"currency"`
}

// Actor is who requested the work.
//
// The worker has no session and no HTTP context, so it cannot look this up: if the
// web tier does not send it, the resulting row is unattributable. That is why the
// decoder treats a missing actor on a payroll event as a hard error.
type Actor struct {
	ID    *int64 `json:"id"`
	Email string `json:"email"`
	Role  string `json:"role"`
}

// Envelope is the decoded Pub/Sub message body.
type Envelope struct {
	SchemaVersion string          `json:"schema_version"`
	EventID       string          `json:"event_id"`
	EventType     string          `json:"event_type"`
	RequestID     string          `json:"request_id"`
	OccurredAt    string          `json:"occurred_at"`
	Source        string          `json:"source"`
	TraceID       string          `json:"trace_id"`
	Tenant        TenantRef       `json:"tenant"`
	Actor         Actor           `json:"actor"`
	Payload       json.RawMessage `json:"payload"`
}

// Decode parses and validates a raw message body.
func Decode(data []byte) (*Envelope, error) {
	var env Envelope

	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("malformed envelope: %w", err)
	}

	if env.SchemaVersion != SchemaVersion {
		return nil, fmt.Errorf("unsupported schema_version %q (worker speaks %q)", env.SchemaVersion, SchemaVersion)
	}

	switch {
	case env.EventID == "":
		return nil, fmt.Errorf("envelope is missing event_id")
	case env.RequestID == "":
		return nil, fmt.Errorf("envelope is missing request_id")
	case env.EventType == "":
		return nil, fmt.Errorf("envelope is missing event_type")
	case env.Tenant.ID == "":
		return nil, fmt.Errorf("envelope is missing tenant.id")
	}

	// Attribution is mandatory on the money-moving event. Everything else can be
	// reconstructed from the data; who authorised a payroll run cannot.
	if env.EventType == EventPayrollCalculateRequested && env.Actor.Email == "" {
		return nil, fmt.Errorf("payroll event %s has no actor; refusing to write an unattributable run", env.EventID)
	}

	return &env, nil
}

// Age reports how long the event has been in flight, which is the number worth
// alerting on: it covers publish latency plus subscription backlog.
func (e *Envelope) Age() time.Duration {
	t, err := time.Parse(time.RFC3339, e.OccurredAt)
	if err != nil {
		return 0
	}

	return time.Since(t)
}

// UnmarshalPayload decodes the event-specific body into dst.
func (e *Envelope) UnmarshalPayload(dst any) error {
	if len(e.Payload) == 0 {
		return fmt.Errorf("event %s has an empty payload", e.EventID)
	}

	if err := json.Unmarshal(e.Payload, dst); err != nil {
		return fmt.Errorf("event %s has an undecodable payload: %w", e.EventID, err)
	}

	return nil
}
