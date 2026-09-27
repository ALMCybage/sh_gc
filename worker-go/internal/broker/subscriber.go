package broker

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/pubsub"
)

// MessageFunc handles one raw Pub/Sub message. It is responsible for calling
// Ack or Nack exactly once.
type MessageFunc func(ctx context.Context, sub string, msg *pubsub.Message)

// Subscriber wraps the Pub/Sub client and runs pull subscriptions.
type Subscriber struct {
	client *pubsub.Client
	logger *slog.Logger

	maxOutstanding int
	numGoroutines  int
	ackExtension   time.Duration
}

// NewSubscriber creates the Pub/Sub client. PUBSUB_EMULATOR_HOST is honoured by
// the client library, so local runs need no extra wiring.
func NewSubscriber(
	ctx context.Context,
	projectID string,
	maxOutstanding, numGoroutines int,
	ackExtension time.Duration,
	logger *slog.Logger,
) (*Subscriber, error) {
	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		return nil, fmt.Errorf("pubsub client: %w", err)
	}

	return &Subscriber{
		client:         client,
		logger:         logger,
		maxOutstanding: maxOutstanding,
		numGoroutines:  numGoroutines,
		ackExtension:   ackExtension,
	}, nil
}

// Receive blocks pulling from one subscription until ctx is cancelled.
//
// MaxOutstandingMessages is the backpressure lever that makes horizontal scaling
// work: each pod leases a bounded amount of work, the rest stays in the
// subscription backlog, and the HPA reacts to that backlog by adding pods.
func (s *Subscriber) Receive(ctx context.Context, subscriptionID string, fn MessageFunc) error {
	sub := s.client.Subscription(subscriptionID)

	exists, err := sub.Exists(ctx)
	if err != nil {
		return fmt.Errorf("check subscription %s: %w", subscriptionID, err)
	}

	if !exists {
		return fmt.Errorf("subscription %s does not exist", subscriptionID)
	}

	sub.ReceiveSettings = pubsub.ReceiveSettings{
		MaxOutstandingMessages: s.maxOutstanding,
		NumGoroutines:          s.numGoroutines,
		// Long-running payroll runs keep extending the ack deadline in the
		// background rather than letting the message be redelivered mid-flight.
		MaxExtension:        s.ackExtension,
		MaxExtensionPeriod:  60 * time.Second,
		MaxOutstandingBytes: 64 * 1024 * 1024,
	}

	s.logger.Info("subscription listening",
		"subscription", subscriptionID,
		"max_outstanding", s.maxOutstanding,
		"goroutines", s.numGoroutines,
	)

	// Receive spawns a goroutine per message and returns when ctx is cancelled.
	if err := sub.Receive(ctx, func(ctx context.Context, msg *pubsub.Message) {
		fn(ctx, subscriptionID, msg)
	}); err != nil && ctx.Err() == nil {
		return fmt.Errorf("receive %s: %w", subscriptionID, err)
	}

	s.logger.Info("subscription stopped", "subscription", subscriptionID)

	return nil
}

// Close releases the client.
func (s *Subscriber) Close() error {
	return s.client.Close()
}
