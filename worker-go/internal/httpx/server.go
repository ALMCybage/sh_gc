// Package httpx serves the worker's probe and metrics endpoints. The worker
// takes no application traffic; this exists so Kubernetes can tell whether the
// pod is healthy and so the HPA has something to scale on.
package httpx

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"worker-go/internal/metrics"
	"worker-go/internal/status"
	"worker-go/internal/tenant"
)

// Server bundles the probe endpoints.
type Server struct {
	http   *http.Server
	logger *slog.Logger
}

// Options configures the probe server.
type Options struct {
	Addr     string
	Pool     *tenant.Pool
	Statuses status.Writer
	Metrics  *metrics.Registry
	Logger   *slog.Logger
	// Ready is flipped once every subscription is attached.
	Ready func() bool
}

// New builds the probe server.
func New(opts Options) *Server {
	mux := http.NewServeMux()

	// Liveness: process is up and the HTTP loop is responsive. Deliberately does
	// not touch MySQL or Firestore, so a dependency blip cannot trigger a
	// restart loop that makes the outage worse.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
		defer cancel()

		checks := map[string]any{}
		healthy := true

		if opts.Ready != nil && !opts.Ready() {
			checks["subscriptions"] = "attaching"
			healthy = false
		} else {
			checks["subscriptions"] = "ok"
		}

		if err := opts.Pool.Ping(ctx); err != nil {
			checks["mysql"] = err.Error()
			healthy = false
		} else {
			checks["mysql"] = "ok"
		}

		if err := opts.Statuses.Ping(ctx); err != nil {
			checks["firestore"] = err.Error()
			healthy = false
		} else {
			checks["firestore"] = "ok"
		}

		code := http.StatusOK
		state := "ready"

		if !healthy {
			code = http.StatusServiceUnavailable
			state = "degraded"
		}

		writeJSON(w, code, map[string]any{
			"status":    state,
			"checks":    checks,
			"in_flight": opts.Metrics.InFlight(),
		})
	})

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		opts.Metrics.WritePrometheus(w)
	})

	return &Server{
		http: &http.Server{
			Addr:              opts.Addr,
			Handler:           mux,
			ReadHeaderTimeout: 5 * time.Second,
		},
		logger: opts.Logger,
	}
}

// Start serves in the background.
func (s *Server) Start() {
	go func() {
		s.logger.Info("probe server listening", "addr", s.http.Addr)

		if err := s.http.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.logger.Error("probe server failed", "error", err)
		}
	}()
}

// Shutdown stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	return s.http.Shutdown(ctx)
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
