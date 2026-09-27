package broker

import (
	"strings"
	"testing"
)

// A real envelope captured from the Laravel app. This is the contract test: if the
// web tier changes its output shape, this fails.
const validPayrollEnvelope = `{
  "schema_version": "2",
  "event_id": "3b45cec5-d32c-401d-8126-baff42a2d0b3",
  "event_type": "payroll.calculate.requested",
  "request_id": "18395769-7e7c-4b01-afe7-6d6091b29498",
  "occurred_at": "2026-09-13T10:39:48Z",
  "source": "web-api",
  "trace_id": "105445aa7843bc8bf206b12000100000",
  "tenant": {"id": "acme", "database": "tenant_acme", "currency": "USD"},
  "actor": {"id": 2, "email": "admin@acme.test", "role": "admin"},
  "payload": {
    "period_start": "2026-09-01",
    "period_end": "2026-09-15",
    "employee_ids": [],
    "include_commission": true,
    "tax_rate": 0.22,
    "notes": null
  }
}`

func TestDecodeValidEnvelope(t *testing.T) {
	env, err := Decode([]byte(validPayrollEnvelope))
	if err != nil {
		t.Fatalf("Decode returned an unexpected error: %v", err)
	}

	if env.EventType != EventPayrollCalculateRequested {
		t.Errorf("event_type = %q", env.EventType)
	}

	if env.Tenant.ID != "acme" || env.Tenant.Database != "tenant_acme" {
		t.Errorf("tenant = %+v", env.Tenant)
	}

	if env.Actor.Email != "admin@acme.test" || env.Actor.Role != "admin" {
		t.Errorf("actor = %+v", env.Actor)
	}

	if env.Actor.ID == nil || *env.Actor.ID != 2 {
		t.Errorf("actor id = %v, want 2", env.Actor.ID)
	}
}

func TestDecodeRejectsWrongSchemaVersion(t *testing.T) {
	// A v1 producer must be refused rather than processed with a missing actor.
	body := strings.Replace(validPayrollEnvelope, `"schema_version": "2"`, `"schema_version": "1"`, 1)

	_, err := Decode([]byte(body))
	if err == nil {
		t.Fatal("Decode accepted a v1 envelope; it must refuse an unknown schema version")
	}

	if !strings.Contains(err.Error(), "schema_version") {
		t.Errorf("error should mention schema_version, got %q", err)
	}
}

// A payroll run with no attribution is not an acceptable degraded outcome: an
// auditor will ask who authorised it, and "we do not know" is not an answer.
func TestDecodeRejectsPayrollWithoutActor(t *testing.T) {
	body := strings.Replace(
		validPayrollEnvelope,
		`"actor": {"id": 2, "email": "admin@acme.test", "role": "admin"},`,
		`"actor": {"id": null, "email": "", "role": ""},`,
		1,
	)

	_, err := Decode([]byte(body))
	if err == nil {
		t.Fatal("Decode accepted a payroll event with no actor")
	}

	if !strings.Contains(err.Error(), "unattributable") {
		t.Errorf("error should explain why, got %q", err)
	}
}

func TestDecodeRequiredFields(t *testing.T) {
	tests := []struct {
		name    string
		body    string
		wantErr string
	}{
		{
			name:    "malformed json",
			body:    `{"schema_version": "2", `,
			wantErr: "malformed envelope",
		},
		{
			name:    "missing event_id",
			body:    `{"schema_version":"2","event_type":"x","request_id":"r","tenant":{"id":"acme"}}`,
			wantErr: "event_id",
		},
		{
			name:    "missing request_id",
			body:    `{"schema_version":"2","event_id":"e","event_type":"x","tenant":{"id":"acme"}}`,
			wantErr: "request_id",
		},
		{
			name:    "missing tenant id",
			body:    `{"schema_version":"2","event_id":"e","event_type":"x","request_id":"r","tenant":{}}`,
			wantErr: "tenant.id",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Decode([]byte(tc.body))
			if err == nil {
				t.Fatalf("Decode(%s) should have failed", tc.name)
			}

			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error %q should mention %q", err, tc.wantErr)
			}
		})
	}
}

func TestUnmarshalPayload(t *testing.T) {
	env, err := Decode([]byte(validPayrollEnvelope))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}

	var payload struct {
		PeriodStart string  `json:"period_start"`
		TaxRate     float64 `json:"tax_rate"`
	}

	if err := env.UnmarshalPayload(&payload); err != nil {
		t.Fatalf("UnmarshalPayload: %v", err)
	}

	if payload.PeriodStart != "2026-09-01" || payload.TaxRate != 0.22 {
		t.Errorf("payload = %+v", payload)
	}
}

func TestAgeIsZeroForUnparseableTimestamp(t *testing.T) {
	// Age feeds the queue-lag metric. A malformed timestamp must not produce a
	// wild value that triggers a false alert.
	env := &Envelope{OccurredAt: "not-a-timestamp"}

	if got := env.Age(); got != 0 {
		t.Errorf("Age() = %v, want 0", got)
	}
}
