<?php

namespace Tests\Feature;

use App\Auth\Role;
use App\Models\Employee;
use App\Tenancy\TenantManager;
use Tests\TestCase;

/**
 * The regression guard for the cross-tenant hole.
 *
 * These tests exist because the first version of this application honoured a
 * client-supplied X-Tenant header ahead of the Host header, and the only thing
 * stopping a cross-tenant read was a coincidence of session cookie names. Every
 * assertion below fails loudly if that behaviour comes back.
 */
class TenancyIsolationTest extends TestCase
{
    public function test_tenant_is_resolved_from_the_host_header(): void
    {
        $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/whoami'))
            ->assertOk()
            ->assertJsonPath('tenant.id', 'acme');

        // Switching tenants inside one test needs the session cleared, or the
        // request inherits the previous tenant's session. See TestCase::resetSession.
        $this->resetSession();

        $this->withHeaders($this->tenantHeaders('whiteknight'))
            ->getJson($this->tenantUrl('whiteknight', '/api/v1/whoami'))
            ->assertOk()
            ->assertJsonPath('tenant.id', 'whiteknight');
    }

    /**
     * THE CRITICAL ONE.
     *
     * A request aimed at acme's hostname carrying "X-Tenant: whiteknight" must be
     * served acme's data. If this fails, any client can read another tenant's
     * schema by adding one header.
     */
    public function test_x_tenant_header_cannot_override_the_host(): void
    {
        $this->withHeaders($this->tenantHeaders('acme', ['X-Tenant' => 'whiteknight']))
            ->getJson($this->tenantUrl('acme', '/api/v1/whoami'))
            ->assertOk()
            ->assertJsonPath('tenant.id', 'acme');
    }

    public function test_header_is_never_trusted_in_production_even_if_configured(): void
    {
        // Someone sets the flag by mistake in a production ConfigMap.
        config(['tenancy.trust_header' => true]);
        app()->detectEnvironment(fn () => 'production');

        $this->assertFalse(
            app(TenantManager::class)->headerIsTrusted(),
            'The tenant header must never be trusted when APP_ENV=production.'
        );
    }

    public function test_unknown_tenant_host_is_rejected(): void
    {
        $this->getJson($this->tenantUrl('ghost', '/api/v1/whoami'))
            ->assertNotFound()
            ->assertJsonPath('message', 'Unknown tenant.');
    }

    /**
     * Each tenant's rows live in a different schema. Reading through the API must
     * never cross that boundary.
     */
    public function test_employees_are_scoped_to_the_requesting_tenant(): void
    {
        $this->seedEmployee('acme', 'ACME-1');
        $this->seedEmployee('whiteknight', 'WK-1');

        $this->actingAsUser('acme', Role::ADMIN);

        $response = $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/employees'));

        $response->assertOk()
            ->assertJsonCount(1, 'data')
            ->assertJsonPath('data.0.employee_code', 'ACME-1');

        $this->assertStringNotContainsString('WK-1', $response->getContent());
    }

    /**
     * A user exists only inside their own tenant's schema, so the same credentials
     * cannot authenticate against another tenant.
     */
    public function test_credentials_do_not_work_across_tenants(): void
    {
        $this->makeUser('acme', Role::ADMIN, 'shared@example.test');

        $this->withHeaders($this->tenantHeaders('whiteknight'))
            ->postJson($this->tenantUrl('whiteknight', '/api/v1/auth/login'), [
                'email' => 'shared@example.test',
                'password' => 'password',
            ])
            ->assertStatus(422);
    }

    /**
     * A session established for one tenant must be refused on another, even if the
     * cookie somehow reaches it. This is EnsureSessionTenant doing its job.
     */
    public function test_session_works_on_its_own_tenant(): void
    {
        $cookies = $this->loginWithSession('acme', Role::ADMIN);

        $this->withCookies($cookies)
            ->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/auth/user'))
            ->assertOk()
            ->assertJsonPath('data.tenant.id', 'acme');
    }

    /**
     * In a browser, acme's session cookie never reaches whiteknight: it is
     * host-only and named per tenant. This test removes that protection on purpose
     * - it takes acme's session id and presents it under the cookie name
     * whiteknight expects - to prove EnsureSessionTenant catches it anyway.
     *
     * That matters because the cookie-scoping defence is implicit. A shared
     * SESSION_DOMAIN, a reverted cookie name, or a future path-based tenant scheme
     * would switch it off silently, and the consequence is severe: user id 1 exists
     * in every tenant schema and is a different real person in each.
     */
    public function test_session_cannot_be_replayed_against_another_tenant(): void
    {
        $cookies = $this->loginWithSession('acme', Role::ADMIN);
        $acmeSessionId = $cookies['sequifi_acme_session'] ?? null;

        $this->assertNotNull($acmeSessionId, 'The login response did not set a tenant session cookie.');

        $response = $this->withCookies(['sequifi_whiteknight_session' => $acmeSessionId])
            ->withHeaders($this->tenantHeaders('whiteknight'))
            ->getJson($this->tenantUrl('whiteknight', '/api/v1/auth/user'));

        $response->assertStatus(401);

        // Assert WHICH control fired. A 401 from the auth guard would also pass the
        // status check while proving nothing about the tenant binding.
        $this->assertStringContainsString(
            'does not belong to this tenant',
            $response->getContent(),
            'The request was rejected, but not by the session/tenant binding check.'
        );
    }

    public function test_cache_and_session_keys_are_namespaced_per_tenant(): void
    {
        $manager = app(TenantManager::class);

        $manager->setCurrent($manager->findOrFail('acme'));
        $this->assertSame('tenant:acme', config('cache.prefix'));
        $this->assertSame('sequifi_acme_session', config('session.cookie'));

        $manager->setCurrent($manager->findOrFail('whiteknight'));
        $this->assertSame('tenant:whiteknight', config('cache.prefix'));
        $this->assertSame('sequifi_whiteknight_session', config('session.cookie'));
    }

    public function test_database_connection_switches_with_the_tenant(): void
    {
        $manager = app(TenantManager::class);

        $manager->setCurrent($manager->findOrFail('acme'));
        $acme = config('database.connections.tenant.database');

        $manager->setCurrent($manager->findOrFail('whiteknight'));
        $whiteknight = config('database.connections.tenant.database');

        $this->assertNotSame($acme, $whiteknight, 'The tenant connection did not switch schemas.');
        $this->assertStringContainsString('acme', $acme);
        $this->assertStringContainsString('whiteknight', $whiteknight);
    }

    private function seedEmployee(string $tenant, string $code): void
    {
        $manager = app(TenantManager::class);

        $manager->runFor($manager->findOrFail($tenant), function () use ($code) {
            Employee::query()->create([
                'employee_code' => $code,
                'first_name' => 'Test',
                'last_name' => 'Person',
                'email' => strtolower($code).'@example.test',
                'department' => 'Sales',
                'base_salary' => 50000,
                'commission_rate' => 0.05,
                'is_active' => true,
            ]);
        });

        $manager->forget();
    }
}
