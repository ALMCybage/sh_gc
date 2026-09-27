// Command worker is the Go calculation-engine microservice.
//
// It pulls from two Pub/Sub subscriptions (payroll-calc-events and sales-import),
// runs the work with one goroutine per message, and commits the result to the
// calling tenant's MySQL schema in Cloud SQL. Request status transitions are
// mirrored into Firestore so the Laravel API can report progress.
package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"worker-go/internal/broker"
	"worker-go/internal/config"
	"worker-go/internal/handler"
	"worker-go/internal/httpx"
	"worker-go/internal/logging"
	"worker-go/internal/metrics"
	"worker-go/internal/status"
	"worker-go/internal/tenant"
	"worker-go/internal/worker"
)

// Injected at build time via -ldflags (see Dockerfile).
var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	logger := newLogger()

	if err := run(logger); err != nil {
		logger.Error("worker exited with an error", "error", err)
		os.Exit(1)
	}

	logger.Info("worker stopped cleanly")
}

func run(logger *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	// SIGTERM is what GKE sends before evicting a pod (node upgrade, scale-down,
	// spot preemption). Cancelling this context stops the subscriptions from
	// leasing new messages while in-flight work finishes.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	registry, err := tenant.NewRegistry(cfg.TenantsJSON, cfg.SchemaPrefix)
	if err != nil {
		return err
	}

	tenants := registry.All()
	names := make([]string, 0, len(tenants))

	for _, t := range tenants {
		names = append(names, t.ID+"->"+t.Database)
	}

	logger.Info("worker starting",
		"worker", cfg.WorkerName,
		"version", version,
		"commit", commit,
		"project", cfg.ProjectID,
		"tenants", names,
		"pubsub_emulator", cfg.UsingPubSubEmulator(),
		"firestore_emulator", cfg.UsingFirestoreEmulator(),
	)

	registryMetrics := metrics.New()

	pool := tenant.NewPool(cfg.DB, cfg.DB.MaxOpenSchemas)
	pool.OnEvict(func(schema string) {
		registryMetrics.SchemaPoolEvicted()
		logger.Info("evicted tenant connection pool", "schema", schema)
	})

	defer func() { _ = pool.Close() }()

	statuses, err := newStatusWriter(ctx, cfg, logger)
	if err != nil {
		return err
	}

	defer func() { _ = statuses.Close() }()

	processor := worker.New(worker.Options{
		Handlers:     []handler.Handler{handler.NewPayroll(), handler.NewSales()},
		Registry:     registry,
		Pool:         pool,
		Statuses:     statuses,
		Metrics:      registryMetrics,
		Logger:       logger,
		WorkerName:   cfg.WorkerName,
		QueryTimeout: cfg.DB.QueryTimeout,
		MaxRetries:   cfg.MaxRetries,
	})

	subscriber, err := broker.NewSubscriber(
		ctx, cfg.ProjectID, cfg.MaxOutstandingMessages, cfg.NumGoroutines, cfg.AckDeadline, logger,
	)
	if err != nil {
		return err
	}

	defer func() { _ = subscriber.Close() }()

	var attached atomic.Int32

	subscriptions := []string{cfg.PayrollSubscription, cfg.SalesSubscription}

	probes := httpx.New(httpx.Options{
		Addr:     cfg.HTTPAddr,
		Pool:     pool,
		Statuses: statuses,
		Metrics:  registryMetrics,
		Logger:   logger,
		Ready:    func() bool { return int(attached.Load()) == len(subscriptions) },
	})
	probes.Start()

	// Refresh the pool gauges on a ticker rather than on every message: a scrape
	// every 30s does not need per-message precision, and this keeps the hot path
	// free of metric bookkeeping.
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				open, capacity, _ := pool.Stats()
				registryMetrics.SetSchemaPoolGauges(open, capacity)
			}
		}
	}()

	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		errs []error
	)

	receiveCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	for _, subscription := range subscriptions {
		subscription := subscription

		wg.Add(1)

		go func() {
			defer wg.Done()

			attached.Add(1)
			defer attached.Add(-1)

			if err := subscriber.Receive(receiveCtx, subscription, processor.Handle); err != nil {
				mu.Lock()
				errs = append(errs, err)
				mu.Unlock()

				// One dead subscription must not leave the pod half-working and
				// still passing readiness: bring the whole worker down and let
				// Kubernetes restart it.
				cancel()
			}
		}()
	}

	<-receiveCtx.Done()

	logger.Info("shutdown signal received, draining in-flight work",
		"in_flight", registryMetrics.InFlight(), "timeout", cfg.ShutdownTimeout)

	drained := make(chan struct{})

	go func() {
		wg.Wait()
		close(drained)
	}()

	select {
	case <-drained:
	case <-time.After(cfg.ShutdownTimeout):
		logger.Warn("drain timed out, exiting anyway", "in_flight", registryMetrics.InFlight())
	}

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	if err := probes.Shutdown(shutdownCtx); err != nil {
		logger.Warn("probe server shutdown failed", "error", err)
	}

	mu.Lock()
	defer mu.Unlock()

	return errors.Join(errs...)
}

func newStatusWriter(ctx context.Context, cfg *config.Config, logger *slog.Logger) (status.Writer, error) {
	if cfg.StatusDriver == "none" {
		logger.Warn("status tracking disabled (STATUS_DRIVER=none)")

		return status.NoopWriter{Logger: logger}, nil
	}

	return status.NewFirestoreWriter(ctx, cfg.ProjectID, cfg.FirestoreDatabase, cfg.FirestoreCollection, logger)
}

// newLogger emits JSON on stderr with the field names Cloud Logging promotes
// (severity, message, trace). See internal/logging for why that matters.
func newLogger() *slog.Logger {
	return logging.New(
		os.Getenv("LOG_LEVEL"),
		"worker",
		version,
		os.Getenv("GOOGLE_CLOUD_PROJECT"),
	)
}
