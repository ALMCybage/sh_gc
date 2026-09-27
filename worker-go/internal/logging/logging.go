// Package logging produces JSON that Cloud Logging actually parses.
//
// THE BUG THIS FIXES
// slog's JSONHandler writes {"level":"INFO","msg":"..."}. Cloud Logging promotes
// "severity" and "message" out of a structured payload and ignores "level" and
// "msg", so every worker log line - including errors - was ingested at DEFAULT
// severity. Nothing could be filtered by level, and no severity-based alert policy
// had anything to fire on.
package logging

import (
	"context"
	"log/slog"
	"os"
	"strings"
)

// TraceKey is the field Cloud Logging uses to group entries into one trace.
const TraceKey = "logging.googleapis.com/trace"

// New builds the worker's logger.
//
// service and version are attached to every line so a single Cloud Logging query
// can separate two revisions running side by side during a canary.
func New(level, service, version, projectID string) *slog.Logger {
	handler := slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level:       parseLevel(level),
		ReplaceAttr: replaceAttr,
	})

	logger := slog.New(&traceHandler{Handler: handler, projectID: projectID}).With(
		"service", service,
		"version", version,
	)

	slog.SetDefault(logger)

	return logger
}

// replaceAttr renames slog's built-ins to the fields Cloud Logging understands.
func replaceAttr(groups []string, attr slog.Attr) slog.Attr {
	// Only rewrite top-level keys; a nested attribute called "level" is the
	// caller's data, not slog's.
	if len(groups) > 0 {
		return attr
	}

	switch attr.Key {
	case slog.LevelKey:
		level, ok := attr.Value.Any().(slog.Level)
		if !ok {
			return attr
		}

		return slog.String("severity", severityFor(level))

	case slog.MessageKey:
		return slog.String("message", attr.Value.String())

	case slog.TimeKey:
		// Cloud Logging accepts RFC3339 in "time"; slog already emits that.
		return attr
	}

	return attr
}

// severityFor maps slog levels onto Cloud Logging severities.
func severityFor(level slog.Level) string {
	switch {
	case level < slog.LevelInfo:
		return "DEBUG"
	case level < slog.LevelWarn:
		return "INFO"
	case level < slog.LevelError:
		return "WARNING"
	case level < slog.LevelError+4:
		return "ERROR"
	default:
		// Reserved for the "we are about to exit" case, which should page.
		return "CRITICAL"
	}
}

// traceHandler promotes a trace_id attribute into the field that makes Cloud
// Logging stitch the web request and this worker's execution into one trace.
//
// Without this the correlation exists in the data but not in the UI: you would
// have to copy a trace id and search for it by hand, which in an incident is the
// difference between one click and five minutes.
type traceHandler struct {
	slog.Handler
	projectID string
}

func (h *traceHandler) Handle(ctx context.Context, record slog.Record) error {
	if h.projectID == "" {
		return h.Handler.Handle(ctx, record)
	}

	var traceID string

	record.Attrs(func(attr slog.Attr) bool {
		if attr.Key == "trace_id" {
			traceID = attr.Value.String()

			return false
		}

		return true
	})

	if traceID != "" && !strings.HasPrefix(traceID, "projects/") {
		record.AddAttrs(slog.String(TraceKey, "projects/"+h.projectID+"/traces/"+traceID))
	}

	return h.Handler.Handle(ctx, record)
}

func (h *traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &traceHandler{Handler: h.Handler.WithAttrs(attrs), projectID: h.projectID}
}

func (h *traceHandler) WithGroup(name string) slog.Handler {
	return &traceHandler{Handler: h.Handler.WithGroup(name), projectID: h.projectID}
}

func parseLevel(raw string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
