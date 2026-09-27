<?php

namespace App\Services\Messaging;

use App\Services\PubSub\PublishFailedException;
use App\Services\PubSub\Publisher;
use App\Services\Status\RequestStatus;
use App\Services\Status\StatusStore;
use App\Tenancy\TenantManager;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

/**
 * Turns an inbound HTTP command into a Pub/Sub event plus a Firestore status
 * document, then returns immediately. This is the "HTTP 202 Accepted in <150ms"
 * decoupling point: no payroll maths ever runs in a web pod.
 */
class AsyncCommandBus
{
    public function __construct(
        private readonly Publisher $publisher,
        private readonly StatusStore $statuses,
        private readonly TenantManager $tenants,
    ) {
    }

    /**
     * @param  array<string, mixed>  $payload
     * @param  array<string, mixed>  $summary  Extra fields written to the status doc.
     * @return array{request_id: string, event_id: string, message_id: string, status: string, accepted_at: string}
     */
    public function dispatch(
        Request $request,
        string $eventType,
        string $topic,
        array $payload,
        array $summary = [],
    ): array {
        $tenant = $this->tenants->currentOrFail();
        $requestId = (string) Str::uuid();
        $traceId = $this->traceId($request);

        $envelope = Envelope::make(
            eventType: $eventType,
            requestId: $requestId,
            tenant: $tenant,
            actor: Actor::fromUser($request->user()),
            payload: $payload,
            traceId: $traceId,
        );

        // Record the request before publishing, so a client that polls the status
        // URL immediately never gets a 404.
        $this->statuses->put($tenant->id, $requestId, array_merge([
            'status' => RequestStatus::ACCEPTED,
            'event_type' => $eventType,
            'topic' => $topic,
            'event_id' => $envelope->eventId,
            'created_at' => $envelope->occurredAt,
            'trace_id' => $traceId,
            'requested_by' => $envelope->actor->email,
        ], $summary));

        try {
            $messageId = $this->publisher->publish($topic, $envelope->toArray(), $envelope->attributes());
        } catch (PublishFailedException $e) {
            $this->statuses->put($tenant->id, $requestId, [
                'status' => RequestStatus::FAILED,
                'error' => 'Unable to enqueue the request: '.$e->getMessage(),
                'failed_stage' => 'publish',
            ]);

            throw $e;
        }

        $this->statuses->put($tenant->id, $requestId, [
            'status' => RequestStatus::QUEUED,
            'message_id' => $messageId,
        ]);

        Log::info('Async command published.', [
            'event_type' => $eventType,
            'topic' => $topic,
            'request_id' => $requestId,
            'message_id' => $messageId,
            'actor' => $envelope->actor->email,
        ]);

        return [
            'request_id' => $requestId,
            'event_id' => $envelope->eventId,
            'message_id' => $messageId,
            'status' => RequestStatus::QUEUED,
            'accepted_at' => $envelope->occurredAt,
        ];
    }

    /**
     * Google's trace header is "TRACE_ID/SPAN_ID;o=1"; only the trace id is
     * propagated, so worker logs can be correlated with the originating request.
     */
    private function traceId(Request $request): ?string
    {
        $header = $request->header('X-Cloud-Trace-Context');

        return $header ? Str::before((string) $header, '/') : null;
    }
}
