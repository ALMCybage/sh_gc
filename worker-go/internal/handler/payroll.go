package handler

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"worker-go/internal/broker"
	"worker-go/internal/status"
)

// PayrollPayload is the body of a payroll.calculate.requested event.
type PayrollPayload struct {
	PeriodStart       string  `json:"period_start"`
	PeriodEnd         string  `json:"period_end"`
	EmployeeIDs       []int64 `json:"employee_ids"`
	IncludeCommission bool    `json:"include_commission"`
	TaxRate           float64 `json:"tax_rate"`
	Notes             *string `json:"notes"`
}

// Payroll is the calculation engine. This file owns the I/O; the arithmetic lives
// in calculator.go so it can be tested without a database.
type Payroll struct{}

// NewPayroll builds the handler.
func NewPayroll() *Payroll { return &Payroll{} }

// EventType implements Handler.
func (*Payroll) EventType() string { return broker.EventPayrollCalculateRequested }

// MaxTaxRate mirrors the API's validation ceiling. Checked again here because the
// worker must not assume the only producer is the current version of the web tier.
const MaxTaxRate = 0.6

// Handle computes and commits a payroll run.
func (h *Payroll) Handle(ctx context.Context, job Job) (map[string]any, error) {
	started := time.Now()

	var payload PayrollPayload
	if err := job.Envelope.UnmarshalPayload(&payload); err != nil {
		return nil, &PermanentError{Err: err}
	}

	periodStart, periodEnd, err := parsePeriod(payload.PeriodStart, payload.PeriodEnd)
	if err != nil {
		return nil, &PermanentError{Err: err}
	}

	if payload.TaxRate < 0 || payload.TaxRate > MaxTaxRate {
		return nil, Permanent("tax_rate %.4f is outside the accepted range 0..%.2f", payload.TaxRate, MaxTaxRate)
	}

	// Inclusive day count: a 1st-to-15th period is 15 paid days, not 14.
	paidDays := int(periodEnd.Sub(periodStart).Hours()/24) + 1

	currency := job.Envelope.Tenant.Currency
	if currency == "" {
		currency = "USD"
	}

	tx, err := job.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}

	defer func() { _ = tx.Rollback() }()

	if err := claimEvent(ctx, tx, job); err != nil {
		return nil, err
	}

	employees, err := loadEmployees(ctx, tx, payload.EmployeeIDs)
	if err != nil {
		return nil, err
	}

	if len(employees) == 0 {
		return nil, Permanent("no matching employees in schema %s", job.Tenant.Database)
	}

	commissionBase := map[int64]Money{}
	if payload.IncludeCommission {
		if commissionBase, err = loadCommissionBase(ctx, tx, periodStart, periodEnd); err != nil {
			return nil, err
		}
	}

	lines, totals := CalculatePayroll(PayrollInput{
		Employees:      employees,
		CommissionBase: commissionBase,
		PaidDays:       paidDays,
		TaxRate:        payload.TaxRate,
		DaysInYear:     DefaultDaysInYear,
	})

	runID, err := insertRun(ctx, tx, job, payload, periodStart, periodEnd, currency, totals, started)
	if err != nil {
		return nil, err
	}

	if err := insertLines(ctx, tx, runID, lines); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit payroll run: %w", err)
	}

	return map[string]any{
		"status":           status.Completed,
		"payroll_run_id":   runID,
		"employee_count":   totals.EmployeeCount,
		"gross_total":      totals.Gross.Float(),
		"commission_total": totals.Commission.Float(),
		"tax_total":        totals.Tax.Float(),
		"net_total":        totals.Net.Float(),
		"currency":         currency,
		"paid_days":        paidDays,
		"requested_by":     job.Envelope.Actor.Email,
		"processed_by":     job.Worker,
		"duration_ms":      time.Since(started).Milliseconds(),
		"completed_at":     time.Now().UTC().Format(time.RFC3339),
		"result_location":  fmt.Sprintf("%s.payroll_runs", job.Tenant.Database),
		"delivery_attempt": job.DeliveryAttempt,
	}, nil
}

// loadEmployees reads the payroll population. With no explicit ids it takes every
// active employee, which is the common "run payroll for everyone" case.
func loadEmployees(ctx context.Context, tx *sql.Tx, ids []int64) ([]EmployeeComp, error) {
	query := `SELECT id, base_salary, commission_rate FROM employees WHERE is_active = 1`
	args := []any{}

	if len(ids) > 0 {
		query = `SELECT id, base_salary, commission_rate FROM employees WHERE id IN (` +
			strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",") + `)`
		args = make([]any, 0, len(ids))

		for _, id := range ids {
			args = append(args, id)
		}
	}

	rows, err := tx.QueryContext(ctx, query+" ORDER BY id", args...)
	if err != nil {
		return nil, fmt.Errorf("load employees: %w", err)
	}

	defer func() { _ = rows.Close() }()

	var out []EmployeeComp

	for rows.Next() {
		var (
			id             int64
			baseSalaryRaw  string
			commissionRate float64
		)

		if err := rows.Scan(&id, &baseSalaryRaw, &commissionRate); err != nil {
			return nil, fmt.Errorf("scan employee: %w", err)
		}

		salary, err := ParseMoney(baseSalaryRaw)
		if err != nil {
			return nil, &PermanentError{Err: fmt.Errorf("employee %d: %w", id, err)}
		}

		out = append(out, EmployeeComp{ID: id, AnnualSalary: salary, CommissionRate: commissionRate})
	}

	return out, rows.Err()
}

// loadCommissionBase sums each employee's sales inside the period. This is the
// join between the two async flows: rows imported by the sales-import handler feed
// straight into the next payroll run.
func loadCommissionBase(ctx context.Context, tx *sql.Tx, from, to time.Time) (map[int64]Money, error) {
	rows, err := tx.QueryContext(ctx,
		`SELECT employee_id, COALESCE(SUM(amount), 0)
		   FROM sales_records
		  WHERE employee_id IS NOT NULL
		    AND sold_at >= ? AND sold_at < ?
		  GROUP BY employee_id`,
		from, to.AddDate(0, 0, 1),
	)
	if err != nil {
		return nil, fmt.Errorf("load commission base: %w", err)
	}

	defer func() { _ = rows.Close() }()

	out := map[int64]Money{}

	for rows.Next() {
		var (
			employeeID int64
			totalRaw   string
		)

		if err := rows.Scan(&employeeID, &totalRaw); err != nil {
			return nil, fmt.Errorf("scan commission base: %w", err)
		}

		total, err := ParseMoney(totalRaw)
		if err != nil {
			return nil, err
		}

		out[employeeID] = total
	}

	return out, rows.Err()
}

func insertRun(
	ctx context.Context,
	tx *sql.Tx,
	job Job,
	payload PayrollPayload,
	periodStart, periodEnd time.Time,
	currency string,
	totals PayrollTotals,
	started time.Time,
) (int64, error) {
	// request_id is unique, so a manual replay of the same request cleans up its
	// own previous output (payroll_lines cascade) instead of erroring.
	if _, err := tx.ExecContext(ctx, `DELETE FROM payroll_runs WHERE request_id = ?`, job.Envelope.RequestID); err != nil {
		return 0, fmt.Errorf("clear previous run: %w", err)
	}

	var notes any
	if payload.Notes != nil {
		notes = *payload.Notes
	}

	var actorID any
	if job.Envelope.Actor.ID != nil {
		actorID = *job.Envelope.Actor.ID
	}

	res, err := tx.ExecContext(ctx,
		`INSERT INTO payroll_runs
		    (request_id, requested_by_id, requested_by_email, period_start, period_end,
		     status, employee_count, gross_total, tax_total, commission_total, net_total,
		     currency, processed_by, duration_ms, notes, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, 'COMPLETED', ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())`,
		job.Envelope.RequestID,
		actorID,
		job.Envelope.Actor.Email,
		periodStart.Format("2006-01-02"),
		periodEnd.Format("2006-01-02"),
		totals.EmployeeCount,
		totals.Gross.String(),
		totals.Tax.String(),
		totals.Commission.String(),
		totals.Net.String(),
		currency,
		job.Worker,
		time.Since(started).Milliseconds(),
		notes,
	)
	if err != nil {
		return 0, fmt.Errorf("insert payroll run: %w", err)
	}

	return res.LastInsertId()
}

func insertLines(ctx context.Context, tx *sql.Tx, runID int64, lines []PayrollLine) error {
	const cols = 7
	// Stay well under MySQL's max_allowed_packet and the 65535 placeholder limit.
	const batchSize = 500

	stmt := `INSERT INTO payroll_lines
	           (payroll_run_id, employee_id, gross_amount, tax_amount, commission_amount, net_amount, created_at)
	         VALUES `

	for start := 0; start < len(lines); start += batchSize {
		end := start + batchSize
		if end > len(lines) {
			end = len(lines)
		}

		batch := lines[start:end]
		args := make([]any, 0, len(batch)*cols)
		now := time.Now().UTC()

		for _, l := range batch {
			args = append(args,
				runID, l.EmployeeID,
				l.Gross.String(), l.Tax.String(), l.Commission.String(), l.Net.String(),
				now,
			)
		}

		if _, err := tx.ExecContext(ctx, stmt+placeholders(len(batch), cols), args...); err != nil {
			if isForeignKeyViolation(err) {
				return &PermanentError{Err: fmt.Errorf("payroll line references a missing employee: %w", err)}
			}

			return fmt.Errorf("insert payroll lines: %w", err)
		}
	}

	return nil
}

func parsePeriod(startRaw, endRaw string) (time.Time, time.Time, error) {
	start, err := time.ParseInLocation("2006-01-02", startRaw, time.UTC)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid period_start %q: %w", startRaw, err)
	}

	end, err := time.ParseInLocation("2006-01-02", endRaw, time.UTC)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid period_end %q: %w", endRaw, err)
	}

	if end.Before(start) {
		return time.Time{}, time.Time{}, errors.New("period_end is before period_start")
	}

	return start, end, nil
}
