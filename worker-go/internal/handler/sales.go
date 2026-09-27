package handler

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"worker-go/internal/broker"
	"worker-go/internal/status"
)

// SalesRow is one record in a sales import.
type SalesRow struct {
	ExternalID string  `json:"external_id"`
	RepEmail   string  `json:"rep_email"`
	Product    *string `json:"product"`
	Amount     float64 `json:"amount"`
	Currency   string  `json:"currency"`
	SoldAt     string  `json:"sold_at"`
}

// SalesPayload is the body of a sales.import.requested event.
type SalesPayload struct {
	Source string     `json:"source"`
	Rows   []SalesRow `json:"rows"`
}

// Sales imports sales rows into the tenant schema.
type Sales struct{}

// NewSales builds the handler.
func NewSales() *Sales { return &Sales{} }

// EventType implements Handler.
func (*Sales) EventType() string { return broker.EventSalesImportRequested }

// Handle upserts every row in one transaction.
func (h *Sales) Handle(ctx context.Context, job Job) (map[string]any, error) {
	started := time.Now()

	var payload SalesPayload
	if err := job.Envelope.UnmarshalPayload(&payload); err != nil {
		return nil, &PermanentError{Err: err}
	}

	if len(payload.Rows) == 0 {
		return nil, Permanent("sales import contains no rows")
	}

	tx, err := job.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}

	defer func() { _ = tx.Rollback() }()

	if err := claimEvent(ctx, tx, job); err != nil {
		return nil, err
	}

	// One lookup for the whole batch instead of a query per row.
	repToEmployee, err := resolveReps(ctx, tx, payload.Rows)
	if err != nil {
		return nil, err
	}

	currency := job.Envelope.Tenant.Currency
	if currency == "" {
		currency = "USD"
	}

	var (
		total     Money
		unmatched []string
	)

	type preparedRow struct {
		externalID string
		employeeID any
		repEmail   string
		product    any
		amount     Money
		currency   string
		soldAt     time.Time
	}

	prepared := make([]preparedRow, 0, len(payload.Rows))
	seen := make(map[string]struct{}, len(payload.Rows))

	for i, row := range payload.Rows {
		if row.ExternalID == "" {
			return nil, Permanent("row %d is missing external_id", i)
		}

		// Two rows with the same external_id inside one batch would make the
		// upsert's behaviour depend on statement order; reject it outright.
		if _, dup := seen[row.ExternalID]; dup {
			return nil, Permanent("external_id %q appears twice in the same import", row.ExternalID)
		}

		seen[row.ExternalID] = struct{}{}

		soldAt, err := parseSoldAt(row.SoldAt)
		if err != nil {
			return nil, &PermanentError{Err: fmt.Errorf("row %d (%s): %w", i, row.ExternalID, err)}
		}

		var employeeID any
		if id, ok := repToEmployee[strings.ToLower(row.RepEmail)]; ok {
			employeeID = id
		} else {
			// Keep the revenue, flag the orphan. Dropping the row would silently
			// under-report the tenant's sales.
			unmatched = append(unmatched, row.RepEmail)
		}

		var product any
		if row.Product != nil && *row.Product != "" {
			product = *row.Product
		}

		rowCurrency := strings.ToUpper(row.Currency)
		if rowCurrency == "" {
			rowCurrency = currency
		}

		amount := MoneyFromFloat(row.Amount)
		total += amount

		prepared = append(prepared, preparedRow{
			externalID: row.ExternalID,
			employeeID: employeeID,
			repEmail:   row.RepEmail,
			product:    product,
			amount:     amount,
			currency:   rowCurrency,
			soldAt:     soldAt,
		})
	}

	const cols = 11
	const batchSize = 400

	stmt := `INSERT INTO sales_records
	           (request_id, imported_by_email, external_id, employee_id, rep_email, product,
	            amount, currency, sold_at, created_at, updated_at)
	         VALUES `

	// external_id is unique, so a Pub/Sub redelivery (or a corrected re-send from
	// the source system) updates the existing row rather than double-counting.
	const onDuplicate = ` ON DUPLICATE KEY UPDATE
	           request_id = VALUES(request_id),
	           imported_by_email = VALUES(imported_by_email),
	           employee_id = VALUES(employee_id),
	           rep_email = VALUES(rep_email),
	           product = VALUES(product),
	           amount = VALUES(amount),
	           currency = VALUES(currency),
	           sold_at = VALUES(sold_at),
	           updated_at = VALUES(updated_at)`

	var affected int64

	for start := 0; start < len(prepared); start += batchSize {
		end := start + batchSize
		if end > len(prepared) {
			end = len(prepared)
		}

		batch := prepared[start:end]
		args := make([]any, 0, len(batch)*cols)
		now := time.Now().UTC()

		for _, r := range batch {
			args = append(args,
				job.Envelope.RequestID, job.Envelope.Actor.Email, r.externalID, r.employeeID,
				r.repEmail, r.product, r.amount.String(), r.currency, r.soldAt, now, now,
			)
		}

		res, err := tx.ExecContext(ctx, stmt+placeholders(len(batch), cols)+onDuplicate, args...)
		if err != nil {
			if isForeignKeyViolation(err) {
				return nil, &PermanentError{Err: fmt.Errorf("sales row references a missing employee: %w", err)}
			}

			return nil, fmt.Errorf("upsert sales rows: %w", err)
		}

		n, err := res.RowsAffected()
		if err == nil {
			affected += n
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit sales import: %w", err)
	}

	summary := map[string]any{
		"status":           status.Completed,
		"source":           payload.Source,
		"rows_received":    len(payload.Rows),
		"rows_written":     affected,
		"total_amount":     total.Float(),
		"currency":         currency,
		"requested_by":     job.Envelope.Actor.Email,
		"processed_by":     job.Worker,
		"duration_ms":      time.Since(started).Milliseconds(),
		"completed_at":     time.Now().UTC().Format(time.RFC3339),
		"result_location":  fmt.Sprintf("%s.sales_records", job.Tenant.Database),
		"delivery_attempt": job.DeliveryAttempt,
	}

	if len(unmatched) > 0 {
		summary["unmatched_rep_emails"] = dedupe(unmatched)
		summary["warning"] = "some rows were stored without an employee link"
	}

	return summary, nil
}

// resolveReps maps rep emails to employee ids in a single query.
func resolveReps(ctx context.Context, tx *sql.Tx, rows []SalesRow) (map[string]int64, error) {
	emails := make([]any, 0, len(rows))
	seen := make(map[string]struct{}, len(rows))

	for _, r := range rows {
		email := strings.ToLower(strings.TrimSpace(r.RepEmail))
		if email == "" {
			continue
		}

		if _, ok := seen[email]; ok {
			continue
		}

		seen[email] = struct{}{}
		emails = append(emails, email)
	}

	out := make(map[string]int64, len(emails))

	if len(emails) == 0 {
		return out, nil
	}

	query := `SELECT id, LOWER(email) FROM employees WHERE LOWER(email) IN (` +
		strings.TrimSuffix(strings.Repeat("?,", len(emails)), ",") + `)`

	dbRows, err := tx.QueryContext(ctx, query, emails...)
	if err != nil {
		return nil, fmt.Errorf("resolve sales reps: %w", err)
	}

	defer func() { _ = dbRows.Close() }()

	for dbRows.Next() {
		var (
			id    int64
			email string
		)

		if err := dbRows.Scan(&id, &email); err != nil {
			return nil, fmt.Errorf("scan sales rep: %w", err)
		}

		out[email] = id
	}

	return out, dbRows.Err()
}

func parseSoldAt(raw string) (time.Time, error) {
	layouts := []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02"}

	for _, layout := range layouts {
		if t, err := time.ParseInLocation(layout, raw, time.UTC); err == nil {
			return t.UTC(), nil
		}
	}

	return time.Time{}, fmt.Errorf("unparseable sold_at %q", raw)
}

func dedupe(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))

	for _, v := range in {
		if _, ok := seen[v]; ok {
			continue
		}

		seen[v] = struct{}{}
		out = append(out, v)
	}

	return out
}
