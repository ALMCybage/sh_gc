<?php

namespace Tests\Feature;

use App\Auth\Role;
use App\Models\Employee;
use App\Tenancy\TenantManager;
use Tests\TestCase;

/**
 * Before this existed, every POST minted a fresh request_id server-side, so a
 * double-clicked button or a client retry after a timeout that had actually
 * succeeded produced a SECOND payroll run for the same period. The worker's
 * processed_events guard does not help: it deduplicates redeliveries of one event,
 * not two distinct submissions.
 */
class IdempotencyTest extends TestCase
{
    private function payload(array $overrides = []): array
    {
        return array_merge([
            'period_start' => '2026-09-01',
            'period_end' => '2026-09-15',
            'include_commission' => true,
            'tax_rate' => 0.22,
        ], $overrides);
    }

    /** Named submitPayroll, not post(): TestCase::post() already exists. */
    private function submitPayroll(array $headers, array $payload)
    {
        return $this->withHeaders($this->tenantHeaders('acme', $headers))
            ->postJson($this->tenantUrl('acme', '/api/v1/payroll/calculations'), $payload);
    }

    protected function setUp(): void
    {
        parent::setUp();

        $manager = app(TenantManager::class);
        $manager->runFor($manager->findOrFail('acme'), function () {
            Employee::query()->create([
                'employee_code' => 'EMP-1', 'first_name' => 'Test', 'last_name' => 'Person',
                'email' => 'emp1@example.test', 'department' => 'Sales',
                'base_salary' => 50000, 'commission_rate' => 0.05, 'is_active' => true,
            ]);
        });
        $manager->forget();

        $this->actingAsUser('acme', Role::ADMIN);
    }

    /**
     * Mandatory, not optional. An optional guard only protects the clients that
     * remember to opt in, and the failure it prevents is one that shows up in
     * production rather than in testing.
     */
    public function test_missing_key_is_rejected(): void
    {
        $this->submitPayroll([], $this->payload())
            ->assertStatus(400)
            ->assertJsonPath('message', 'This endpoint requires an Idempotency-Key header.');
    }

    public function test_short_key_is_rejected(): void
    {
        $this->submitPayroll(['Idempotency-Key' => 'abc'], $this->payload())
            ->assertStatus(400);
    }

    public function test_first_submission_is_accepted(): void
    {
        $this->submitPayroll($this->idempotencyKey('run-2026-09-h1'), $this->payload())
            ->assertStatus(202)
            ->assertJsonPath('data.status', 'QUEUED')
            ->assertHeaderMissing('Idempotency-Replayed');
    }

    /**
     * THE ONE THAT MATTERS: the retry must not queue a second payroll run.
     */
    public function test_repeated_key_replays_the_original_response(): void
    {
        $first = $this->submitPayroll($this->idempotencyKey('run-2026-09-h1'), $this->payload());
        $first->assertStatus(202);

        $second = $this->submitPayroll($this->idempotencyKey('run-2026-09-h1'), $this->payload());

        $second->assertStatus(202)
            ->assertHeader('Idempotency-Replayed', 'true');

        $this->assertSame(
            $first->json('data.request_id'),
            $second->json('data.request_id'),
            'A retry produced a new request_id, which means a second payroll run was queued.'
        );

        $this->assertSame($first->json('data.message_id'), $second->json('data.message_id'));
    }

    /**
     * Reusing a key for different data is almost always a client bug. Silently
     * accepting it would hide that bug and could return the wrong result for the
     * wrong period.
     */
    public function test_same_key_with_a_different_payload_conflicts(): void
    {
        $this->submitPayroll($this->idempotencyKey('run-2026-09-h1'), $this->payload())->assertStatus(202);

        $this->submitPayroll($this->idempotencyKey('run-2026-09-h1'), $this->payload(['period_end' => '2026-09-30']))
            ->assertStatus(409)
            ->assertJsonPath('message', 'This Idempotency-Key was already used with a different payload.');
    }

    public function test_different_keys_queue_separate_requests(): void
    {
        // Keys must be at least 8 characters, so a caller cannot pass something
        // guessable or accidentally collide with another operation.
        $first = $this->submitPayroll($this->idempotencyKey('run-alpha-1'), $this->payload());
        $second = $this->submitPayroll($this->idempotencyKey('run-bravo-2'), $this->payload());

        $first->assertStatus(202);
        $second->assertStatus(202);

        $this->assertNotSame($first->json('data.request_id'), $second->json('data.request_id'));
    }

    /**
     * Key order in the JSON body must not change the fingerprint, or a client that
     * serialises its map differently on a retry would get a spurious 409.
     */
    public function test_fingerprint_ignores_key_ordering(): void
    {
        $this->submitPayroll($this->idempotencyKey('run-order'), [
            'period_start' => '2026-09-01',
            'period_end' => '2026-09-15',
            'tax_rate' => 0.22,
            'include_commission' => true,
        ])->assertStatus(202);

        $this->submitPayroll($this->idempotencyKey('run-order'), [
            'tax_rate' => 0.22,
            'include_commission' => true,
            'period_end' => '2026-09-15',
            'period_start' => '2026-09-01',
        ])
            ->assertStatus(202)
            ->assertHeader('Idempotency-Replayed', 'true');
    }

    /**
     * A rejected submission must not burn the key: the client fixes the payload and
     * retries, and that retry has to be allowed through.
     */
    public function test_validation_failure_releases_the_key(): void
    {
        $this->submitPayroll($this->idempotencyKey('run-retry'), $this->payload(['period_start' => 'nonsense']))
            ->assertStatus(422);

        $this->submitPayroll($this->idempotencyKey('run-retry'), $this->payload())
            ->assertStatus(202)
            ->assertHeaderMissing('Idempotency-Replayed');
    }

    /**
     * Keys are namespaced per tenant, so two tenants picking the same key (very
     * likely - "payroll-september") never collide.
     */
    public function test_keys_are_scoped_per_tenant(): void
    {
        $this->submitPayroll($this->idempotencyKey('shared-key-value'), $this->payload())->assertStatus(202);

        $this->resetSession();
        $this->actingAsUser('whiteknight', Role::ADMIN);

        $manager = app(TenantManager::class);
        $manager->runFor($manager->findOrFail('whiteknight'), function () {
            Employee::query()->create([
                'employee_code' => 'WK-1', 'first_name' => 'W', 'last_name' => 'K',
                'email' => 'wk1@example.test', 'department' => 'Sales',
                'base_salary' => 50000, 'commission_rate' => 0, 'is_active' => true,
            ]);
        });

        $this->withHeaders($this->tenantHeaders('whiteknight', $this->idempotencyKey('shared-key-value')))
            ->postJson($this->tenantUrl('whiteknight', '/api/v1/payroll/calculations'), $this->payload())
            ->assertStatus(202)
            ->assertHeaderMissing('Idempotency-Replayed');
    }
}
