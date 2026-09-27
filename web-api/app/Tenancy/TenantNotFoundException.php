<?php

namespace App\Tenancy;

use RuntimeException;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;

class TenantNotFoundException extends RuntimeException implements HttpExceptionInterface
{
    public function __construct(private readonly string $identifier)
    {
        parent::__construct("Unknown tenant [{$identifier}].");
    }

    public function identifier(): string
    {
        return $this->identifier;
    }

    public function getStatusCode(): int
    {
        return 404;
    }

    public function getHeaders(): array
    {
        return [];
    }
}
