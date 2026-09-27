<?php

namespace App\Services\Status;

class NullStatusStore implements StatusStore
{
    public function put(string $tenantId, string $requestId, array $fields): void
    {
    }

    public function get(string $tenantId, string $requestId): ?array
    {
        return null;
    }

    public function ping(): bool
    {
        return true;
    }
}
