<?php

namespace Tests\Feature;

use App\Auth\Ability;
use App\Auth\Role;
use App\Models\Employee;
use App\Tenancy\TenantManager;
use Tests\TestCase;

/**
 * Before this layer existed, any authenticated user could run payroll for the whole
 * tenant. These tests pin the role matrix so a new route cannot quietly ship
 * without a check, and so widening a role is a deliberate, visible change.
 */
class AuthorizationTest extends TestCase
{
    private function payrollPayload(): array
    {
        return [
            'period_start' => '2026-09-01',
            'period_end' => '2026-09-15',
            'include_commission' => true,
            'tax_rate' => 0.22,
        ];
    }

    /** Running payroll moves money, so it is the narrowest permission. */
    public function test_only_owner_and_admin_can_run_payroll(): void
    {
        $allowed = [Role::OWNER => 202, Role::ADMIN => 202];
        $denied = [Role::OPERATOR => 403, Role::VIEWER => 403];

        foreach ($allowed + $denied as $role => $expected) {
            $this->refreshApplication();
            $this->setUp();

            $this->seedEmployee('acme');
            $this->actingAsUser('acme', $role);

            $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
                ->postJson($this->tenantUrl('acme', '/api/v1/payroll/calculations'), $this->payrollPayload())
                ->assertStatus($expected);
        }
    }

    public function test_operator_can_import_sales_but_not_run_payroll(): void
    {
        $this->actingAsUser('acme', Role::OPERATOR);

        $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
            ->postJson($this->tenantUrl('acme', '/api/v1/sales/imports'), [
                'source' => 'test',
                'rows' => [[
                    'external_id' => 'SO-1',
                    'rep_email' => 'rep@example.test',
                    'amount' => 100.0,
                    'sold_at' => '2026-09-01T00:00:00Z',
                ]],
            ])
            ->assertStatus(202);

        $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
            ->postJson($this->tenantUrl('acme', '/api/v1/payroll/calculations'), $this->payrollPayload())
            ->assertStatus(403)
            ->assertJsonPath('role', Role::OPERATOR);
    }

    public function test_viewer_cannot_import_sales(): void
    {
        $this->actingAsUser('acme', Role::VIEWER);

        $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
            ->postJson($this->tenantUrl('acme', '/api/v1/sales/imports'), [
                'source' => 'test',
                'rows' => [[
                    'external_id' => 'SO-1',
                    'rep_email' => 'rep@example.test',
                    'amount' => 100.0,
                    'sold_at' => '2026-09-01T00:00:00Z',
                ]],
            ])
            ->assertStatus(403);
    }

    public function test_only_privileged_roles_see_the_audit_log(): void
    {
        $this->actingAsUser('acme', Role::ADMIN);
        $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/audit-logs'))
            ->assertOk();

        $this->refreshApplication();
        $this->setUp();

        $this->actingAsUser('acme', Role::OPERATOR);
        $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/audit-logs'))
            ->assertStatus(403);
    }

    /**
     * "Who works here" and "what they are paid" are different sensitivities. An
     * operator needs the first without the second.
     */
    public function test_compensation_is_hidden_from_roles_without_the_ability(): void
    {
        $this->seedEmployee('acme');
        $this->actingAsUser('acme', Role::ADMIN);

        $adminResponse = $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/employees'));

        $adminResponse->assertOk()
            ->assertJsonPath('meta.includes_compensation', true);

        $this->assertArrayHasKey('base_salary', $adminResponse->json('data.0'));

        $this->refreshApplication();
        $this->setUp();

        $this->seedEmployee('acme');
        $this->actingAsUser('acme', Role::OPERATOR);

        $operatorResponse = $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/employees'));

        $operatorResponse->assertOk()
            ->assertJsonPath('meta.includes_compensation', false);

        $this->assertArrayNotHasKey('base_salary', $operatorResponse->json('data.0'));
        $this->assertArrayNotHasKey('commission_rate', $operatorResponse->json('data.0'));
    }

    /**
     * The cache key includes the compensation flag. Without that, an admin's cached
     * payload (salaries included) would be served to an operator for the next 60
     * seconds - a quiet way to leak data across roles.
     */
    public function test_compensation_cache_is_not_shared_between_roles(): void
    {
        $this->seedEmployee('acme');

        // Warm the cache as an admin first.
        $this->actingAsUser('acme', Role::ADMIN);
        $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/employees'))
            ->assertOk();

        // Same tenant, same filters, lower-privileged role, same app instance so the
        // array cache is genuinely warm.
        $operator = $this->makeUser('acme', Role::OPERATOR, 'operator2@acme.test');
        $this->actingAs($operator);

        $response = $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/employees'));

        $response->assertOk();
        $this->assertArrayNotHasKey(
            'base_salary',
            $response->json('data.0'),
            'A cached admin response leaked compensation to an operator.'
        );
    }

    public function test_deactivated_user_loses_every_ability(): void
    {
        $manager = app(TenantManager::class);
        $manager->setCurrent($manager->findOrFail('acme'));

        $user = $this->makeUser('acme', Role::OWNER, 'owner@acme.test');
        $user->update(['is_active' => false]);

        $this->actingAs($user->fresh());

        // Gate::before short-circuits everything, so one flag revokes access
        // immediately rather than waiting for the session to expire.
        $this->withHeaders($this->tenantHeaders('acme', $this->idempotencyKey()))
            ->postJson($this->tenantUrl('acme', '/api/v1/payroll/calculations'), $this->payrollPayload())
            ->assertStatus(403);

        $this->assertSame([], $user->fresh()->abilities());
    }

    public function test_deactivated_user_cannot_log_in(): void
    {
        $user = $this->makeUser('acme', Role::ADMIN, 'inactive@acme.test');

        $manager = app(TenantManager::class);
        $manager->runFor($manager->findOrFail('acme'), fn () => $user->update(['is_active' => false]));

        $this->withHeaders($this->tenantHeaders('acme'))
            ->postJson($this->tenantUrl('acme', '/api/v1/auth/login'), [
                'email' => 'inactive@acme.test',
                'password' => 'password',
            ])
            ->assertStatus(422);
    }

    public function test_abilities_are_returned_to_the_client(): void
    {
        $this->actingAsUser('acme', Role::OPERATOR);

        $response = $this->withHeaders($this->tenantHeaders('acme'))
            ->getJson($this->tenantUrl('acme', '/api/v1/auth/user'));

        $abilities = $response->assertOk()->json('data.abilities');

        // The SPA hides what the API would refuse; sending resolved abilities means
        // it never has to reimplement the role matrix and disagree with the server.
        $this->assertContains(Ability::SALES_IMPORT, $abilities);
        $this->assertNotContains(Ability::PAYROLL_RUN, $abilities);
        $this->assertNotContains(Ability::EMPLOYEES_VIEW_COMPENSATION, $abilities);
    }

    public function test_unauthenticated_requests_are_rejected(): void
    {
        foreach (['/api/v1/employees', '/api/v1/payroll/calculations', '/api/v1/audit-logs'] as $path) {
            $this->withHeaders($this->tenantHeaders('acme'))
                ->getJson($this->tenantUrl('acme', $path))
                ->assertStatus(401);
        }
    }

    private function seedEmployee(string $tenant): void
    {
        $manager = app(TenantManager::class);

        $manager->runFor($manager->findOrFail($tenant), function () {
            Employee::query()->create([
                'employee_code' => 'EMP-1',
                'first_name' => 'Test',
                'last_name' => 'Person',
                'email' => 'emp1@example.test',
                'department' => 'Sales',
                'base_salary' => 50000,
                'commission_rate' => 0.05,
                'is_active' => true,
            ]);
        });

        $manager->forget();
    }
}
