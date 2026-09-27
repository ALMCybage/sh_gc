<?php

namespace Tests;

use App\Auth\Role;
use App\Models\User;
use App\Tenancy\TenantManager;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

abstract class TestCase extends BaseTestCase
{
    use CreatesApplication;

    /**
     * Tenants used by the suite. Real per-tenant SQLite files rather than one
     * shared in-memory database, because the whole point of these tests is that
     * the schemas are actually separate - a shared database would make a
     * cross-tenant leak invisible.
     *
     * @var array<int, string>
     */
    protected array $tenants = ['acme', 'whiteknight'];

    /** Unique per test run, so nothing leaks between tests. */
    private string $token = '';

    protected function setUp(): void
    {
        parent::setUp();

        // A fresh filename per test rather than deleting and recreating one.
        // Windows keeps a lock on an open SQLite file, so unlink() fails silently
        // and the next test inherits the previous test's rows - which produced a
        // confusing "duplicate email" failure rather than an obvious one.
        $this->token = Str::random(8);

        $this->configureTenantRegistry();
        $this->migrateTenants();
    }

    protected function tearDown(): void
    {
        // Release the PDO handles before trying to remove the files.
        foreach (['tenant', 'sqlite'] as $connection) {
            try {
                DB::purge($connection);
            } catch (\Throwable) {
                // Connection may never have been opened.
            }
        }

        foreach ($this->tenants as $tenant) {
            @unlink($this->databasePath($tenant));
        }

        parent::tearDown();
    }

    private function databasePath(string $tenant): string
    {
        return storage_path("framework/testing/t_{$this->token}_{$tenant}.sqlite");
    }

    private function configureTenantRegistry(): void
    {
        $registry = [];

        foreach ($this->tenants as $tenant) {
            $path = $this->databasePath($tenant);

            if (! is_dir(dirname($path))) {
                mkdir(dirname($path), 0777, true);
            }

            touch($path);

            $registry[$tenant] = [
                'name' => ucfirst($tenant).' Ltd',
                'database' => $path,
                'domain' => "{$tenant}.sequifi.com",
                'payroll_currency' => 'USD',
            ];
        }

        Config::set('tenancy.tenants', $registry);
        Config::set('tenancy.fallback', $this->tenants[0]);
    }

    private function migrateTenants(): void
    {
        $manager = app(TenantManager::class);

        foreach ($this->tenants as $id) {
            $manager->runFor($manager->findOrFail($id), function () {
                Artisan::call('migrate', [
                    '--database' => 'tenant',
                    '--path' => 'database/migrations/tenant',
                    '--force' => true,
                ]);
            });
        }

        $manager->forget();
    }

    /**
     * Absolute URL on the tenant's hostname.
     *
     * Tests must address tenants the way production does - by host - and the test
     * client derives HTTP_HOST from the request URL, overriding any Host header you
     * try to set. So the hostname has to be in the URL itself.
     */
    protected function tenantUrl(string $tenant, string $path): string
    {
        return "http://{$tenant}.sequifi.com".$path;
    }

    /**
     * Headers that make Sanctum treat the request as first-party, so the session
     * middleware runs. Without a matching Origin/Referer there is no session at all.
     *
     * @param  array<string, string>  $headers
     * @return array<string, string>
     */
    protected function tenantHeaders(string $tenant, array $headers = []): array
    {
        return array_merge([
            'Origin' => "http://{$tenant}.sequifi.com",
            'Referer' => "http://{$tenant}.sequifi.com/",
            'Accept' => 'application/json',
        ], $headers);
    }

    /**
     * Create a user inside a specific tenant's schema.
     */
    protected function makeUser(string $tenant, string $role = Role::ADMIN, ?string $email = null): User
    {
        $manager = app(TenantManager::class);

        return $manager->runFor($manager->findOrFail($tenant), function () use ($tenant, $role, $email) {
            return User::query()->create([
                'name' => ucfirst($role),
                'email' => $email ?? "{$role}@{$tenant}.test",
                'password' => Hash::make('password'),
                'role' => $role,
                'is_active' => true,
            ]);
        });
    }

    /**
     * Authenticate for the common case, without going through the login endpoint.
     *
     * The tenant is bound first so the user is created in - and read back from -
     * the right schema. EnsureSessionTenant is a no-op here because there is no
     * session; the tests that need to exercise it use loginWithSession().
     */
    protected function actingAsUser(string $tenant, string $role = Role::ADMIN): User
    {
        $user = $this->makeUser($tenant, $role);

        $manager = app(TenantManager::class);
        $manager->setCurrent($manager->findOrFail($tenant));

        $this->actingAs($user);

        return $user;
    }

    /**
     * Log in through the real endpoint and return the response cookies.
     *
     * Laravel's test client does not persist cookies between requests, so a test
     * that needs a genuine browser-like session has to carry them itself. This is
     * what lets the session/tenant binding actually be tested.
     *
     * @return array<string, string>
     */
    protected function loginWithSession(string $tenant, string $role = Role::ADMIN): array
    {
        $user = $this->makeUser($tenant, $role);

        $response = $this->withHeaders($this->tenantHeaders($tenant))
            ->postJson($this->tenantUrl($tenant, '/api/v1/auth/login'), [
                'email' => $user->email,
                'password' => 'password',
            ]);

        $response->assertOk();

        $cookies = [];

        foreach ($response->headers->getCookies() as $cookie) {
            $cookies[$cookie->getName()] = $cookie->getValue();
        }

        return $cookies;
    }

    /**
     * Discard any in-memory session state before the next request.
     *
     * Laravel resolves the session Store once per application instance and reuses
     * it across requests within a test. Store::loadSession() array_merges the
     * handler's data over whatever is already in the object, so attributes from a
     * previous request survive even when no cookie is sent. Any test that issues
     * requests as more than one tenant must call this between them, or the second
     * request inherits the first one's session and fails for the wrong reason.
     */
    protected function resetSession(): void
    {
        $this->flushSession();

        foreach (glob(storage_path('framework/sessions/*')) ?: [] as $file) {
            if (is_file($file) && basename($file) !== '.gitignore') {
                @unlink($file);
            }
        }
    }

    /**
     * A valid Idempotency-Key header for the write endpoints.
     *
     * @return array<string, string>
     */
    protected function idempotencyKey(?string $value = null): array
    {
        return ['Idempotency-Key' => $value ?? 'test-'.bin2hex(random_bytes(8))];
    }
}
