// Package status records the lifecycle of asynchronous API requests in
// Firestore, which is what the Laravel GET /api/v1/requests/{id} endpoint reads.
package status

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Request lifecycle states. Must match App\Services\Status\RequestStatus.
const (
	Accepted   = "ACCEPTED"
	Queued     = "QUEUED"
	Processing = "PROCESSING"
	Completed  = "COMPLETED"
	Failed     = "FAILED"
)

// Writer records status transitions.
type Writer interface {
	Merge(ctx context.Context, tenantID, requestID string, fields map[string]any) error
	Ping(ctx context.Context) error
	Close() error
}

// FirestoreWriter is the production implementation.
type FirestoreWriter struct {
	client     *firestore.Client
	collection string
	logger     *slog.Logger
}

// NewFirestoreWriter connects to Firestore. Honours FIRESTORE_EMULATOR_HOST.
func NewFirestoreWriter(ctx context.Context, projectID, database, collection string, logger *slog.Logger) (*FirestoreWriter, error) {
	var (
		client *firestore.Client
		err    error
	)

	if database == "" || database == "(default)" {
		client, err = firestore.NewClient(ctx, projectID)
	} else {
		client, err = firestore.NewClientWithDatabase(ctx, projectID, database)
	}

	if err != nil {
		return nil, fmt.Errorf("firestore: %w", err)
	}

	return &FirestoreWriter{client: client, collection: collection, logger: logger}, nil
}

// Merge upserts the status document, leaving fields written by the web tier
// (period, row counts, message id) untouched.
func (w *FirestoreWriter) Merge(ctx context.Context, tenantID, requestID string, fields map[string]any) error {
	doc := make(map[string]any, len(fields)+3)
	for k, v := range fields {
		doc[k] = v
	}

	doc["tenant_id"] = tenantID
	doc["request_id"] = requestID
	doc["updated_at"] = time.Now().UTC().Format(time.RFC3339)

	_, err := w.client.
		Collection(w.collection).
		Doc(DocumentID(tenantID, requestID)).
		Set(ctx, doc, firestore.MergeAll)

	if err != nil {
		return fmt.Errorf("firestore merge %s: %w", requestID, err)
	}

	return nil
}

// Ping performs a cheap read to confirm Firestore is reachable.
func (w *FirestoreWriter) Ping(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	_, err := w.client.Collection(w.collection).Limit(1).Documents(ctx).GetAll()
	if err != nil && status.Code(err) != codes.NotFound {
		return err
	}

	return nil
}

// Close releases the gRPC connection.
func (w *FirestoreWriter) Close() error {
	return w.client.Close()
}

// DocumentID partitions the collection by tenant, matching the PHP side.
func DocumentID(tenantID, requestID string) string {
	return tenantID + "__" + requestID
}

// NoopWriter drops every transition. Useful for local runs without Firestore.
type NoopWriter struct{ Logger *slog.Logger }

// Merge logs the transition instead of persisting it.
func (n NoopWriter) Merge(_ context.Context, tenantID, requestID string, fields map[string]any) error {
	if n.Logger != nil {
		n.Logger.Debug("status transition dropped (noop writer)",
			"tenant_id", tenantID, "request_id", requestID, "fields", fields)
	}

	return nil
}

// Ping always succeeds.
func (NoopWriter) Ping(context.Context) error { return nil }

// Close is a no-op.
func (NoopWriter) Close() error { return nil }
