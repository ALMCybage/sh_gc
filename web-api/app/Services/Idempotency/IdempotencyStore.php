<?php

namespace App\Services\Idempotency;

use Illuminate\Contracts\Cache\Repository as Cache;
use Illuminate\Support\Facades\Log;

/**
 * Makes the async write endpoints safe to retry.
 *
 * THE PROBLEM
 * Every POST previously minted a fresh request_id server-side. A double-clicked
 * button, or a client retrying after a timeout that actually succeeded, produced a
 * *second* payroll run for the same period. The worker's processed_events guard
 * does not help: it deduplicates redeliveries of one event, not two distinct
 * submissions.
 *
 * THE CONTRACT
 * The client sends a stable `Idempotency-Key` per logical operation.
 *   - first time      -> the operation runs, and its 202 response is stored
 *   - key seen again, same payload -> the stored response is replayed, no new work
 *   - key seen again, different payload -> 409, because reusing a key for a
 *     different operation is a client bug and silently accepting it would hide it
 *   - concurrent duplicate -> 409 while the first is still in flight
 *
 * Keys are namespaced per tenant, so two tenants can pick the same key.
 */
class IdempotencyStore
{
    /** Long enough to cover any realistic client retry window. */
    public const TTL_SECONDS = 86400;

    /** Guards against two identical requests arriving at once. */
    private const LOCK_SECONDS = 30;

    public function __construct(private readonly Cache $cache)
    {
    }

    /**
     * Claim a key. Returns null when the caller should proceed.
     *
     * @param  array<string, mixed>  $payload
     * @return array{state: string, response?: array<string, mixed>}|null
     */
    public function claim(string $tenantId, string $key, array $payload): ?array
    {
        $cacheKey = $this->key($tenantId, $key);
        $fingerprint = $this->fingerprint($payload);

        $existing = $this->cache->get($cacheKey);

        if ($existing === null) {
            // add() is atomic, so exactly one of two concurrent identical requests
            // wins the claim and the other is told to wait.
            $claimed = $this->cache->add($cacheKey, [
                'state' => 'in_flight',
                'fingerprint' => $fingerprint,
                'claimed_at' => time(),
            ], self::LOCK_SECONDS);

            if ($claimed) {
                return null;
            }

            $existing = $this->cache->get($cacheKey);
        }

        if (! is_array($existing)) {
            return null;
        }

        if (($existing['fingerprint'] ?? null) !== $fingerprint) {
            return ['state' => 'conflict'];
        }

        if (($existing['state'] ?? null) === 'completed') {
            return ['state' => 'completed', 'response' => $existing['response'] ?? []];
        }

        return ['state' => 'in_flight'];
    }

    /**
     * Record the successful response so a later retry replays it verbatim.
     *
     * @param  array<string, mixed>  $payload
     * @param  array<string, mixed>  $response
     */
    public function complete(string $tenantId, string $key, array $payload, array $response): void
    {
        $this->cache->put($this->key($tenantId, $key), [
            'state' => 'completed',
            'fingerprint' => $this->fingerprint($payload),
            'response' => $response,
            'completed_at' => time(),
        ], self::TTL_SECONDS);
    }

    /**
     * Release the claim after a failure, so the client can retry immediately
     * rather than waiting out the lock.
     */
    public function release(string $tenantId, string $key): void
    {
        try {
            $this->cache->forget($this->key($tenantId, $key));
        } catch (\Throwable $e) {
            Log::warning('Could not release idempotency claim.', [
                'key' => $key,
                'error' => $e->getMessage(),
            ]);
        }
    }

    /**
     * Hash of the request body. Retrying the same operation must produce the same
     * fingerprint, so keys are sorted before hashing.
     *
     * @param  array<string, mixed>  $payload
     */
    private function fingerprint(array $payload): string
    {
        $normalised = $this->sortRecursive($payload);

        return hash('sha256', json_encode($normalised, JSON_THROW_ON_ERROR));
    }

    /** @param array<string, mixed> $value */
    private function sortRecursive(array $value): array
    {
        foreach ($value as $key => $item) {
            if (is_array($item)) {
                $value[$key] = $this->sortRecursive($item);
            }
        }

        // Only sort maps; reordering a list would change its meaning.
        if (! array_is_list($value)) {
            ksort($value);
        }

        return $value;
    }

    private function key(string $tenantId, string $key): string
    {
        return 'idempotency:'.$tenantId.':'.hash('sha256', $key);
    }
}
