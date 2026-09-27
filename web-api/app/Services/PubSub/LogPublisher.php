<?php

namespace App\Services\PubSub;

use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

/**
 * No-op publisher for offline development. Logs the exact envelope that would
 * have gone to Pub/Sub so you can still exercise the full HTTP path (and copy
 * the envelope into the Go worker's test fixtures) without GCP or the emulator.
 */
class LogPublisher implements Publisher
{
    public function publish(string $topic, array $payload, array $attributes = []): string
    {
        $messageId = 'local-'.Str::uuid()->toString();

        Log::info('[pubsub:log-driver] publish', [
            'topic' => $topic,
            'message_id' => $messageId,
            'attributes' => $attributes,
            'payload' => $payload,
        ]);

        return $messageId;
    }
}
