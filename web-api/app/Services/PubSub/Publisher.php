<?php

namespace App\Services\PubSub;

interface Publisher
{
    /**
     * Publish one message and return the Pub/Sub message id.
     *
     * @param  string  $topic  Short topic id, e.g. "payroll-calc-events".
     * @param  array<string, mixed>  $payload  JSON-encoded into the message data.
     * @param  array<string, string>  $attributes  Message attributes used by the
     *                                             Go worker for routing/filtering.
     *
     * @throws PublishFailedException
     */
    public function publish(string $topic, array $payload, array $attributes = []): string;
}
