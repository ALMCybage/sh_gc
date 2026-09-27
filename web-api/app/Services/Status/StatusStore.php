<?php

namespace App\Services\Status;

interface StatusStore
{
    /**
     * Create or merge the status document for a request.
     *
     * @param  array<string, mixed>  $fields
     */
    public function put(string $tenantId, string $requestId, array $fields): void;

    /**
     * @return array<string, mixed>|null Null when the request id is unknown.
     */
    public function get(string $tenantId, string $requestId): ?array;

    /**
     * Cheap dependency probe used by the readiness endpoint.
     */
    public function ping(): bool;
}
