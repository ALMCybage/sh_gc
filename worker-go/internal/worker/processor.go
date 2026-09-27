// Package worker wires the Pub/Sub subscriber to the business handlers: decode,
// resolve tenant, run, record status, ack or nack.
package worker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"cloud.google.com/go/pubsub"

	"worker-go/internal/broker"
	"worker-go/internal/handler"
	"worker-go/internal/metrics"
	"worker-go/internal/status"
	"worker-go/internal/tenant"
)

// Processor routes messages to handlers.
type Processor struct {
	handlers     map[string]handler.Handler
	registry     *tenant.Registry
	pool         *tenant.Pool
	statuses     status.Writer
	metrics      *metrics.Registry
	logger       *slog.Logger
	workerName   string
	queryTimeout time.Duration
	maxRetries   int
}

// Options configures a Processor.
type Options struct {
	Handlers     []handler.Handler
	Registry     *tenant.Registry
	Pool         *tenant.Pool
	Statuses     status.Writer
	Metrics      *metrics.Registry
	Logger       *slog.Logger
	WorkerName   string
	QueryTimeout time.Duration
	MaxRetries   int
}

// New builds a Processor from its dependencies.
func New(opts Options) *Processor {
	handlers := make(map[string]handler.Handler, len(opts.Handlers))
	for _, h := range opts.Handlers {
		handlers[h.EventType()] = h
	}

	return &Processor{
		handlers:     handlers,
		registry:     opts.Registry,
		pool:         opts.Pool,
		statuses:     opts.Statuses,
		metrics:      opts.Metrics,
		logger:       opts.Logger,
		workerName:   opts.WorkerName,
		queryTimeout: opts.QueryTimeout,
		maxRetries:   opts.MaxRetries,
	}
}

// Handle is the broker.MessageFunc for every subscription.
func (p *Processor) Handle(ctx context.Context, subscription string, msg *pubsub.Message) {
	p.metrics.MessageReceived()
	defer p.metrics.MessageDone()

	started := time.Now()

	env, err := broker.Decode(msg.Data)
	if err != nil {
		// A body we cannot parse will never parse. Retrying it just blocks the
		// subscription, so ack and let the dead-letter topic keep the evidence.
		p.logger.Error("dropping unparseable message",
			"subscription", subscription, "message_id", msg.ID, "error", err)
		p.metrics.PermanentFailure("unknown")
		msg.Ack()

		return
	}

	logger := p.logger.With(
		"subscription", subscription,
		"message_id", msg.ID,
		"event_id", env.EventID,
		"event_type", env.EventType,
		"request_id", env.RequestID,
		"tenant_id", env.Tenant.ID,
		"trace_id", env.TraceID,
	)

	attempt := deliveryAttempt(msg)

	h, ok := p.handlers[env.EventType]
	if !ok {
		logger.Error("no handler registered for event type")
		p.metrics.PermanentFailure(env.EventType)
		p.recordFailure(ctx, env, "no handler registered for event type "+env.EventType, attempt)
		msg.Ack()

		return
	}

	tnt, err := p.registry.Get(env.Tenant.ID)
	if err != nil {
		logger.Error("unknown tenant", "error", err)
		p.metrics.PermanentFailure(env.EventType)
		p.recordFailure(ctx, env, err.Error(), attempt)
		msg.Ack()

		return
	}

	// The worker's own registry decides the schema. If the event disagrees, that
	// is worth surfacing: it means the two services' registries have drifted.
	if env.Tenant.Database != "" && env.Tenant.Database != tnt.Database {
		logger.Warn("event tenant schema disagrees with the worker registry",
			"event_schema", env.Tenant.Database, "registry_schema", tnt.Database)
	}

	workCtx, cancel := context.WithTimeout(ctx, p.queryTimeout)
	defer cancel()

	db, err := p.pool.For(workCtx, tnt)
	if err != nil {
		// Cloud SQL being unreachable is transient: nack so another pod (or this
		// one, later) retries.
		logger.Error("cannot reach tenant schema", "error", err)
		p.metrics.Failed(env.EventType)
		msg.Nack()

		return
	}

	p.recordStatus(workCtx, env, map[string]any{
		"status":           status.Processing,
		"worker":           p.workerName,
		"subscription":     subscription,
		"delivery_attempt": attempt,
		"queue_lag_ms":     env.Age().Milliseconds(),
		"started_at":       time.Now().UTC().Format(time.RFC3339),
	})

	job := handler.Job{
		Envelope:        env,
		Tenant:          tnt,
		DB:              db,
		Subscription:    subscription,
		Worker:          p.workerName,
		Logger:          logger,
		DeliveryAttempt: attempt,
	}

	summary, err := h.Handle(workCtx, job)

	switch {
	case errors.Is(err, handler.ErrAlreadyProcessed):
		logger.Info("duplicate delivery skipped", "duration_ms", time.Since(started).Milliseconds())
		p.metrics.Duplicate()
		msg.Ack()

	case err == nil:
		duration := time.Since(started).Milliseconds()
		logger.Info("event completed", "duration_ms", duration)
		p.metrics.Completed(env.EventType, duration)
		p.recordStatus(ctx, env, summary)
		msg.Ack()

	case handler.IsPermanent(err):
		logger.Error("permanent failure, acking", "error", err)
		p.metrics.PermanentFailure(env.EventType)
		p.recordFailure(ctx, env, err.Error(), attempt)
		msg.Ack()

	case p.maxRetries > 0 && attempt >= p.maxRetries:
		// Retries exhausted. Give up explicitly so the caller sees FAILED rather
		// than a request stuck in PROCESSING forever.
		logger.Error("retry budget exhausted, acking", "attempt", attempt, "error", err)
		p.metrics.PermanentFailure(env.EventType)
		p.recordFailure(ctx, env, fmt.Sprintf("failed after %d attempts: %v", attempt, err), attempt)
		msg.Ack()

	default:
		logger.Warn("transient failure, nacking for retry", "attempt", attempt, "error", err)
		p.metrics.Failed(env.EventType)
		p.recordStatus(ctx, env, map[string]any{
			"status":           status.Processing,
			"last_error":       err.Error(),
			"delivery_attempt": attempt,
		})
		msg.Nack()
	}
}

func (p *Processor) recordFailure(ctx context.Context, env *broker.Envelope, reason string, attempt int) {
	p.recordStatus(ctx, env, map[string]any{
		"status":           status.Failed,
		"error":            reason,
		"worker":           p.workerName,
		"delivery_attempt": attempt,
		"failed_at":        time.Now().UTC().Format(time.RFC3339),
	})
}

// recordStatus never blocks the ack decision on Firestore: status tracking is
// observability, and losing a transition must not turn into a redelivery loop.
func (p *Processor) recordStatus(ctx context.Context, env *broker.Envelope, fields map[string]any) {
	if len(fields) == 0 {
		return
	}

	writeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()

	if err := p.statuses.Merge(writeCtx, env.Tenant.ID, env.RequestID, fields); err != nil {
		p.logger.Warn("status write failed",
			"request_id", env.RequestID, "tenant_id", env.Tenant.ID, "error", err)
	}
}

// deliveryAttempt reads the attempt counter Pub/Sub attaches when the
// subscription has a dead-letter policy; falls back to the publisher attribute.
func deliveryAttempt(msg *pubsub.Message) int {
	if msg.DeliveryAttempt != nil {
		return *msg.DeliveryAttempt
	}

	if raw, ok := msg.Attributes["delivery_attempt"]; ok {
		if n, err := strconv.Atoi(raw); err == nil {
			return n
		}
	}

	return 1
}
