// Package handler contains the business logic executed by the worker pool: the
// payroll calculation engine and the sales importer.
package handler

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/go-sql-driver/mysql"

	"worker-go/internal/broker"
	"worker-go/internal/tenant"
)

// Job is everything a handler needs to process one event.
type Job struct {
	Envelope     *broker.Envelope
	Tenant       tenant.Tenant
	DB           *sql.DB
	Subscription string
	Worker       string
	Logger       *slog.Logger
	// DeliveryAttempt is the Pub/Sub delivery attempt, when the subscription has
	// a dead-letter policy attached. 0 means unknown.
	DeliveryAttempt int
}

// Handler processes one event type.
type Handler interface {
	EventType() string
	// Handle returns a summary that is merged into the Firestore status document.
	Handle(ctx context.Context, job Job) (map[string]any, error)
}

// PermanentError marks a failure that retrying cannot fix (bad payload, unknown
// tenant, referential integrity violation). The subscriber acks these and marks
// the request FAILED instead of burning the retry budget.
type PermanentError struct{ Err error }

func (e *PermanentError) Error() string { return e.Err.Error() }
func (e *PermanentError) Unwrap() error { return e.Err }

// Permanent wraps err as a non-retryable failure.
func Permanent(format string, args ...any) error {
	return &PermanentError{Err: fmt.Errorf(format, args...)}
}

// IsPermanent reports whether err (or anything it wraps) is permanent.
func IsPermanent(err error) bool {
	var perm *PermanentError

	return errors.As(err, &perm)
}

// ErrAlreadyProcessed signals that this event_id was already committed, so the
// message is a Pub/Sub redelivery and must be acked without re-doing the work.
var ErrAlreadyProcessed = errors.New("event already processed")

// claimEvent inserts the idempotency row. Returning ErrAlreadyProcessed means a
// previous delivery of this exact event already committed its writes.
//
// Because the claim shares the handler's transaction, "claimed" and "work done"
// commit or roll back together - there is no window where an event looks
// processed but its rows are missing.
func claimEvent(ctx context.Context, tx *sql.Tx, job Job) error {
	_, err := tx.ExecContext(ctx,
		`INSERT INTO processed_events (event_id, event_type, subscription, worker, processed_at)
		 VALUES (?, ?, ?, ?, UTC_TIMESTAMP())`,
		job.Envelope.EventID, job.Envelope.EventType, job.Subscription, job.Worker,
	)

	if isDuplicateKey(err) {
		return ErrAlreadyProcessed
	}

	if err != nil {
		return fmt.Errorf("claim event %s: %w", job.Envelope.EventID, err)
	}

	return nil
}

func isDuplicateKey(err error) bool {
	var mysqlErr *mysql.MySQLError

	if errors.As(err, &mysqlErr) {
		return mysqlErr.Number == 1062
	}

	return false
}

// isForeignKeyViolation matches MySQL's "cannot add or update a child row"
// (1452) and "cannot delete or update a parent row" (1451). Retrying cannot fix
// a reference to a row that does not exist, so callers mark these permanent.
func isForeignKeyViolation(err error) bool {
	var mysqlErr *mysql.MySQLError

	if errors.As(err, &mysqlErr) {
		return mysqlErr.Number == 1452 || mysqlErr.Number == 1451
	}

	return false
}

// placeholders builds "(?,?,?),(?,?,?)" for a batch insert of rows*cols values.
func placeholders(rows, cols int) string {
	if rows <= 0 || cols <= 0 {
		return ""
	}

	group := "(" + strings.TrimSuffix(strings.Repeat("?,", cols), ",") + ")"

	return strings.TrimSuffix(strings.Repeat(group+",", rows), ",")
}
