package logging

import (
	"encoding/json"
	"log/slog"
	"testing"
)

// The bug this guards: slog writes {"level":"ERROR","msg":"..."} and Cloud Logging
// ignores both keys, so every line landed at DEFAULT severity and no severity-based
// alert could fire. A regression here is invisible until an incident.
func TestReplaceAttrMapsToCloudLoggingFields(t *testing.T) {
	tests := []struct {
		level slog.Level
		want  string
	}{
		{slog.LevelDebug, "DEBUG"},
		{slog.LevelInfo, "INFO"},
		{slog.LevelWarn, "WARNING"},
		{slog.LevelError, "ERROR"},
		{slog.LevelError + 4, "CRITICAL"},
	}

	for _, tc := range tests {
		attr := replaceAttr(nil, slog.Any(slog.LevelKey, tc.level))

		if attr.Key != "severity" {
			t.Errorf("level key = %q, want \"severity\"", attr.Key)
		}

		if got := attr.Value.String(); got != tc.want {
			t.Errorf("severity for %v = %q, want %q", tc.level, got, tc.want)
		}
	}

	msg := replaceAttr(nil, slog.String(slog.MessageKey, "hello"))
	if msg.Key != "message" {
		t.Errorf("message key = %q, want \"message\"", msg.Key)
	}
}

// Nested keys are caller data, not slog built-ins, and must be left alone.
func TestReplaceAttrLeavesNestedKeysAlone(t *testing.T) {
	attr := replaceAttr([]string{"payload"}, slog.String(slog.MessageKey, "inner"))

	if attr.Key != slog.MessageKey {
		t.Errorf("nested %q was rewritten to %q", slog.MessageKey, attr.Key)
	}
}

func TestSeverityRenderedInOutput(t *testing.T) {
	var buf syncBuffer

	handler := slog.NewJSONHandler(&buf, &slog.HandlerOptions{
		Level:       slog.LevelDebug,
		ReplaceAttr: replaceAttr,
	})

	slog.New(&traceHandler{Handler: handler, projectID: "my-project"}).
		Error("payroll failed", "tenant_id", "acme", "trace_id", "abc123")

	var entry map[string]any
	if err := json.Unmarshal(buf.Bytes(), &entry); err != nil {
		t.Fatalf("output is not valid JSON: %v (%s)", err, buf.String())
	}

	if entry["severity"] != "ERROR" {
		t.Errorf("severity = %v, want ERROR", entry["severity"])
	}

	if entry["message"] != "payroll failed" {
		t.Errorf("message = %v", entry["message"])
	}

	if _, ok := entry["level"]; ok {
		t.Error(`"level" is still present; Cloud Logging ignores it and it duplicates severity`)
	}

	// The field that makes Cloud Logging stitch the web request and this worker's
	// execution into a single trace.
	want := "projects/my-project/traces/abc123"
	if entry[TraceKey] != want {
		t.Errorf("%s = %v, want %v", TraceKey, entry[TraceKey], want)
	}
}

func TestTraceHandlerNoopWithoutProject(t *testing.T) {
	var buf syncBuffer

	handler := slog.NewJSONHandler(&buf, &slog.HandlerOptions{ReplaceAttr: replaceAttr})
	slog.New(&traceHandler{Handler: handler}).Info("no project", "trace_id", "abc123")

	var entry map[string]any
	_ = json.Unmarshal(buf.Bytes(), &entry)

	if _, ok := entry[TraceKey]; ok {
		t.Error("trace field should be omitted when no project id is configured")
	}
}

func TestParseLevel(t *testing.T) {
	cases := map[string]slog.Level{
		"debug":    slog.LevelDebug,
		"DEBUG":    slog.LevelDebug,
		" warn ":   slog.LevelWarn,
		"warning":  slog.LevelWarn,
		"error":    slog.LevelError,
		"":         slog.LevelInfo,
		"nonsense": slog.LevelInfo,
	}

	for input, want := range cases {
		if got := parseLevel(input); got != want {
			t.Errorf("parseLevel(%q) = %v, want %v", input, got, want)
		}
	}
}

// Minimal io.Writer; bytes.Buffer would do but this keeps the intent obvious.
type syncBuffer struct{ data []byte }

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.data = append(b.data, p...)

	return len(p), nil
}

func (b *syncBuffer) Bytes() []byte  { return b.data }
func (b *syncBuffer) String() string { return string(b.data) }
