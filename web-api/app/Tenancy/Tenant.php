<?php

namespace App\Tenancy;

use JsonSerializable;

/**
 * Immutable description of a single tenant.
 *
 * The "database" property is the MySQL schema inside the shared Cloud SQL
 * instance (tenant_acme, tenant_whiteknight, tenant_frdm, ...).
 */
final class Tenant implements JsonSerializable
{
    public function __construct(
        public readonly string $id,
        public readonly string $name,
        public readonly string $database,
        public readonly ?string $domain = null,
        public readonly array $meta = [],
    ) {
    }

    public static function fromRegistry(string $id, array $config): self
    {
        return new self(
            id: $id,
            name: $config['name'] ?? $id,
            database: $config['database'] ?? config('tenancy.schema_prefix').$id,
            domain: $config['domain'] ?? null,
            meta: array_diff_key($config, array_flip(['name', 'database', 'domain'])),
        );
    }

    public function currency(): string
    {
        return $this->meta['payroll_currency'] ?? 'USD';
    }

    public function jsonSerialize(): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'database' => $this->database,
            'domain' => $this->domain,
        ];
    }
}
