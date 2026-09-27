<?php

namespace App\Services\Status;

use Illuminate\Contracts\Cache\Repository as Cache;

/**
 * Offline fallback for request status tracking.
 *
 * Backed by the configured Laravel cache store, so it works with Redis (shared
 * across web pods) or with the local file store (single machine, no services).
 * Note the Go worker cannot write here - use the Firestore driver whenever you
 * want end-to-end status transitions.
 */
class CacheStatusStore implements StatusStore
{
    public function __construct(
        private readonly Cache $cache,
        private readonly int $ttlSeconds = 86400,
    ) {
    }

    public function put(string $tenantId, string $requestId, array $fields): void
    {
        $key = $this->key($tenantId, $requestId);

        $existing = $this->cache->get($key, []);

        $this->cache->put($key, array_merge($existing, $fields, [
            'tenant_id' => $tenantId,
            'request_id' => $requestId,
            'updated_at' => gmdate('Y-m-d\TH:i:s\Z'),
        ]), $this->ttlSeconds);
    }

    public function get(string $tenantId, string $requestId): ?array
    {
        return $this->cache->get($this->key($tenantId, $requestId));
    }

    public function ping(): bool
    {
        $this->cache->put('status-store:ping', 1, 5);

        return true;
    }

    private function key(string $tenantId, string $requestId): string
    {
        return "request-status:{$tenantId}:{$requestId}";
    }
}
