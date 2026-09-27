<?php

namespace App\Tenancy;

use Illuminate\Contracts\Config\Repository as Config;
use Illuminate\Contracts\Foundation\Application;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Dynamic schema router.
 *
 * Web pods stay 100% stateless: nothing about the tenant is remembered between
 * requests. Each request resolves a tenant, points the "tenant" database
 * connection at that tenant's schema, and namespaces the Redis cache keys.
 */
class TenantManager
{
    private ?Tenant $current = null;

    public function __construct(
        private readonly Application $app,
        private readonly Config $config,
    ) {
    }

    /** @return array<string, Tenant> */
    public function all(): array
    {
        $tenants = [];

        foreach ((array) $this->config->get('tenancy.tenants', []) as $id => $definition) {
            $tenants[$id] = Tenant::fromRegistry((string) $id, (array) $definition);
        }

        return $tenants;
    }

    public function find(string $id): ?Tenant
    {
        return $this->all()[$id] ?? null;
    }

    public function findOrFail(string $id): Tenant
    {
        return $this->find($id) ?? throw new TenantNotFoundException($id);
    }

    public function current(): ?Tenant
    {
        return $this->current;
    }

    public function currentOrFail(): Tenant
    {
        return $this->current ?? throw new TenantNotFoundException('<unresolved>');
    }

    /**
     * Resolve the tenant for an inbound request.
     *
     * 1. Host header (acme.sequifi.com -> "acme"). This is the only source that
     *    is authoritative in production, because it is the name the client
     *    resolved and TLS was negotiated for - not a value it can simply assert.
     * 2. X-Tenant header, ONLY when tenancy.trust_header is enabled. Off in
     *    production; see the note in config/tenancy.php.
     * 3. Configured fallback, for localhost and kubelet probes where the host
     *    encodes no tenant.
     *
     * Note the ordering: the Host header wins. Even with the header trusted, a
     * request to a real tenant hostname cannot be redirected by an attacker.
     */
    public function resolveFromRequest(Request $request): Tenant
    {
        if ($fromHost = $this->tenantIdFromHost($request->getHost())) {
            return $this->findOrFail($fromHost);
        }

        if ($this->headerIsTrusted()) {
            $header = (string) $this->config->get('tenancy.header', 'X-Tenant');

            if ($explicit = $request->header($header)) {
                return $this->findOrFail(Str::lower(trim($explicit)));
            }
        }

        return $this->findOrFail((string) $this->config->get('tenancy.fallback'));
    }

    /**
     * The header is never trusted in production, whatever the config says. A
     * mis-set ConfigMap should not be able to reopen a cross-tenant path.
     */
    public function headerIsTrusted(): bool
    {
        if ($this->app->environment('production')) {
            return false;
        }

        return (bool) $this->config->get('tenancy.trust_header', false);
    }

    public function tenantIdFromHost(string $host): ?string
    {
        // Symfony's getHost() already strips the port, but the header may still
        // carry one when the request arrives from a dev proxy.
        $host = Str::lower(Str::before($host, ':'));

        foreach ($this->all() as $tenant) {
            if ($tenant->domain && $tenant->domain === $host) {
                return $tenant->id;
            }
        }

        // A bare IP (pod IP, kube-probe) encodes no tenant.
        if (filter_var($host, FILTER_VALIDATE_IP)) {
            return null;
        }

        foreach ((array) $this->config->get('tenancy.base_domains', []) as $base) {
            $base = Str::lower(trim((string) $base));

            if ($base === '' || ! Str::endsWith($host, '.'.$base)) {
                continue;
            }

            $label = Str::before($host, '.'.$base);

            // Only a single label is a tenant. Anything deeper is not ours.
            if ($label !== '' && ! Str::contains($label, '.')) {
                return $label;
            }
        }

        return null;
    }

    /**
     * Bind the whole runtime (DB schema, cache namespace) to a tenant.
     */
    public function setCurrent(Tenant $tenant): Tenant
    {
        $this->current = $tenant;

        $this->configureDatabase($tenant);
        $this->configureCache($tenant);
        $this->configureSession($tenant);

        $this->app->instance(Tenant::class, $tenant);

        return $tenant;
    }

    public function forget(): void
    {
        $this->current = null;

        $runtime = (string) $this->config->get('tenancy.runtime_connection', 'tenant');

        DB::purge($runtime);
    }

    /**
     * Run a callback with a different tenant bound, then restore the previous
     * one. Used by tenants:migrate and by any cross-tenant console work.
     */
    public function runFor(Tenant $tenant, callable $callback): mixed
    {
        $previous = $this->current;

        $this->setCurrent($tenant);

        try {
            return $callback($tenant);
        } finally {
            $previous ? $this->setCurrent($previous) : $this->forget();
        }
    }

    public function connectionName(): string
    {
        return (string) $this->config->get('tenancy.runtime_connection', 'tenant');
    }

    private function configureDatabase(Tenant $tenant): void
    {
        $template = (string) $this->config->get('tenancy.template_connection', 'mysql');
        $runtime = $this->connectionName();

        $settings = $this->config->get("database.connections.{$template}", []);
        $settings['database'] = $tenant->database;

        $this->config->set("database.connections.{$runtime}", $settings);

        // Drop any PDO handle still pointing at the previous tenant's schema.
        DB::purge($runtime);

        $this->config->set('database.default', $runtime);
    }

    private function configureCache(Tenant $tenant): void
    {
        $store = (string) $this->config->get('cache.default');

        $this->config->set('cache.prefix', 'tenant:'.$tenant->id);

        // Rebuild the store so the new prefix is picked up.
        Cache::forgetDriver($store);
    }

    /**
     * Name the session cookie and the Redis session key per tenant.
     *
     * Tenants already live on separate hostnames, so browser cookies are scoped
     * for us. This is belt and braces for the cases where they are not: a shared
     * dev host, or a future path-based tenant. It must run before StartSession,
     * which is why ResolveTenant sits at the front of the "api" middleware group.
     */
    private function configureSession(Tenant $tenant): void
    {
        $this->config->set('session.cookie', 'sequifi_'.$tenant->id.'_session');

        // The Redis session handler stores through the cache store, which
        // configureCache() has already namespaced with tenant:<id>, so the
        // payloads are isolated too.
    }
}
