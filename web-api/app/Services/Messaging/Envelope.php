<?php

namespace App\Services\Messaging;

use App\Tenancy\Tenant;
use Illuminate\Support\Str;

/**
 * The wire contract between the Laravel web tier and the Go worker.
 *
 * Keep this in sync with worker-go/internal/broker/envelope.go. schema_version is
 * bumped on any breaking change so old workers reject what they cannot understand
 * instead of silently mis-processing it.
 *
 * v2 added the `actor` block. That is an additive change - a v1 worker would
 * simply ignore it - but the version is bumped anyway, because "the worker must
 * record who requested this run" is a requirement, and a worker that cannot do so
 * should refuse the message rather than write an unattributable payroll row.
 */
final class Envelope
{
    public const SCHEMA_VERSION = '2';

    public function __construct(
        public readonly string $eventId,
        public readonly string $eventType,
        public readonly string $requestId,
        public readonly Tenant $tenant,
        public readonly Actor $actor,
        public readonly array $payload,
        public readonly string $occurredAt,
        public readonly string $source = 'web-api',
        public readonly ?string $traceId = null,
    ) {
    }

    public static function make(
        string $eventType,
        string $requestId,
        Tenant $tenant,
        Actor $actor,
        array $payload,
        ?string $traceId = null,
    ): self {
        return new self(
            eventId: (string) Str::uuid(),
            eventType: $eventType,
            requestId: $requestId,
            tenant: $tenant,
            actor: $actor,
            payload: $payload,
            occurredAt: gmdate('Y-m-d\TH:i:s\Z'),
            traceId: $traceId,
        );
    }

    /** @return array<string, mixed> */
    public function toArray(): array
    {
        return [
            'schema_version' => self::SCHEMA_VERSION,
            'event_id' => $this->eventId,
            'event_type' => $this->eventType,
            'request_id' => $this->requestId,
            'occurred_at' => $this->occurredAt,
            'source' => $this->source,
            'trace_id' => $this->traceId,
            'tenant' => [
                'id' => $this->tenant->id,
                'database' => $this->tenant->database,
                'currency' => $this->tenant->currency(),
            ],
            'actor' => $this->actor->toArray(),
            'payload' => $this->payload,
        ];
    }

    /**
     * Pub/Sub message attributes. Cheap to filter on without decoding the body,
     * which is what subscription filters and the worker's router use.
     *
     * The actor's email is deliberately NOT an attribute: attributes appear in
     * Pub/Sub metrics and logs, and personal data does not belong there.
     *
     * @return array<string, string>
     */
    public function attributes(): array
    {
        return array_filter([
            'schema_version' => self::SCHEMA_VERSION,
            'event_type' => $this->eventType,
            'tenant_id' => $this->tenant->id,
            'request_id' => $this->requestId,
            'trace_id' => $this->traceId,
        ], static fn ($value) => $value !== null && $value !== '');
    }
}
