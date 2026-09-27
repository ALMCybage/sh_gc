<?php

namespace Tests\Feature;

use App\Auth\Role;
use App\Models\AuditLog;
use App\Models\Employee;
use App\Services\Audit\AuditLogger;
use App\Tenancy\TenantManager;
use Tests\TestCase;

/**
 * Payroll is financial data. "The system calculated 50,341.53" is not a sufficient
 * record - somebody authorised that run, and an auditor will ask who. The worker
 * records which pod did the arithmetic; this records which human asked for it.
 */
class AuditTrailTest extends TestCase
{
    /** @return \Illuminate\Support\Collection<int, AuditLog> */
    private function logs(string $tenant = 'acme')
    {
        $manager = app(TenantManager::class);

        return $manager->runFor(
            $manager->findOrFail($tenant),
            fn () => AuditLog::query()->orderBy('id')->get()
        );
    }

    private function seedEmployee(string $tenant = 'acme'): void
    {
        $manager = app(TenantManager::class);

        $manager->runFor($manager->findOrFail($tenant), function () {
            Employee::query()->create([
                'employee_code' => 'EMP-1', 'first_name' => 'Test', 'last_name' => 'Person',
                'email' => 'emp1@example.test', 'department' => 'Sales',
                'base_salary' => 50000, 'commission_rate' => 0.05, 'is_active' => true,
            ]);
        });
    }

    public function test_payroll_request_is_attributed_to_the_user(): void
    {
        $this->seedEmployee();
        $user = $this->actingAsUser('acme', Role::ADMIN);

        $response = $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
            ->postJson($this->tenantUrl('acme', '/api/v1/payroll/calculations'), [
                'period_start' => '2026-09-01',
                'period_end' => '2026-09-15',
                'include_commission' => true,
                'tax_rate' => 0.22,
            ]);

        $response->assertStatus(202);

        $entry = $this->logs()->firstWhere('action', AuditLogger::PAYROLL_REQUESTED);

        $this->assertNotNull($entry, 'A payroll request was accepted with no audit entry.');
        $this->assertSame($user->id, $entry->actor_id);
        $this->assertSame($user->email, $entry->actor_email);
        $this->assertSame(Role::ADMIN, $entry->actor_role);
        $this->assertSame('success', $entry->outcome);

        // Correlates the audit entry with the async request and its worker logs.
        $this->assertSame($response->json('data.request_id'), $entry->request_id);

        // Parameters are recorded; the payload is not. "ran payroll for this period"
        // is auditable, the row data is business data that lives elsewhere.
        $this->assertSame('2026-09-01', $entry->context['period_start']);
        $this->assertSame(0.22, $entry->context['tax_rate']);
    }

    public function test_sales_import_is_attributed_to_the_user(): void
    {
        $user = $this->actingAsUser('acme', Role::OPERATOR);

        $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
            ->postJson($this->tenantUrl('acme', '/api/v1/sales/imports'), [
                'source' => 'crm-export',
                'rows' => [[
                    'external_id' => 'SO-1',
                    'rep_email' => 'rep@example.test',
                    'amount' => 1499.99,
                    'sold_at' => '2026-09-01T00:00:00Z',
                ]],
            ])
            ->assertStatus(202);

        $entry = $this->logs()->firstWhere('action', AuditLogger::SALES_IMPORT_REQUESTED);

        $this->assertNotNull($entry);
        $this->assertSame($user->email, $entry->actor_email);
        $this->assertSame('crm-export', $entry->context['source']);
        $this->assertSame(1, $entry->context['row_count']);
    }

    public function test_successful_login_is_recorded(): void
    {
        $this->loginWithSession('acme', Role::ADMIN);

        $entry = $this->logs()->firstWhere('action', AuditLogger::LOGIN_SUCCEEDED);

        $this->assertNotNull($entry);
        $this->assertSame('admin@acme.test', $entry->actor_email);
    }

    /**
     * A burst of these against one account is the signal for credential stuffing, so
     * the attempted identity is recorded even though there is no authenticated user.
     */
    public function test_failed_login_is_recorded_with_the_attempted_email(): void
    {
        $this->makeUser('acme', Role::ADMIN, 'real@acme.test');

        $this->withHeaders($this->tenantHeaders('acme'))
            ->postJson($this->tenantUrl('acme', '/api/v1/auth/login'), [
                'email' => 'real@acme.test',
                'password' => 'wrong-password',
            ])
            ->assertStatus(422);

        $entry = $this->logs()->firstWhere('action', AuditLogger::LOGIN_FAILED);

        $this->assertNotNull($entry);
        $this->assertNull($entry->actor_id, 'A failed login must not be attributed to a user id.');
        $this->assertSame('real@acme.test', $entry->actor_email);
        $this->assertSame('denied', $entry->outcome);
        $this->assertSame('invalid_credentials', $entry->context['reason']);
    }

    /**
     * The trail lives inside the tenant schema, so one tenant can never read
     * another's audit history.
     */
    public function test_audit_trail_is_isolated_per_tenant(): void
    {
        $this->loginWithSession('acme', Role::ADMIN);

        $this->assertGreaterThan(0, $this->logs('acme')->count());
        $this->assertSame(0, $this->logs('whiteknight')->count());
    }

    public function test_audit_log_endpoint_returns_entries(): void
    {
        $this->actingAsUser('acme', Role::ADMIN);

        $response = $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/audit-logs'));

        $response->assertOk()->assertJsonStructure(['data', 'current_page', 'total']);
    }
}
