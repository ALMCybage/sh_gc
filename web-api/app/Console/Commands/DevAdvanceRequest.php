<?php

namespace App\Console\Commands;

use App\Services\Status\RequestStatus;
use App\Services\Status\StatusStore;
use App\Tenancy\TenantManager;
use Illuminate\Console\Command;

/**
 * Development-only test double for the Go worker's status transitions.
 *
 * It moves a request through PROCESSING -> COMPLETED (or FAILED) and writes a
 * plausible summary, so the SPA's polling, terminal-state detection and result
 * rendering can be exercised without MySQL, Pub/Sub and the worker running.
 *
 * It deliberately does NOT do any of the real work - no payroll arithmetic, no
 * row writes. Reimplementing the calculation engine in PHP would create a second
 * source of truth that silently drifts from the Go implementation.
 */
class DevAdvanceRequest extends Command
{
    protected $signature = 'dev:advance-request
        {request : The request_id returned by the 202 response}
        {--tenant=acme : Tenant the request belongs to}
        {--status=COMPLETED : PROCESSING, COMPLETED or FAILED}
        {--kind=payroll : payroll or sales, controls the synthetic summary}
        {--error= : Failure message when --status=FAILED}';

    protected $description = '[dev only] Advance an async request status, standing in for the Go worker';

    public function handle(StatusStore $statuses, TenantManager $tenants): int
    {
        if ($this->laravel->environment('production')) {
            $this->components->error('dev:advance-request is not available in production.');

            return self::FAILURE;
        }

        $tenant = $tenants->findOrFail((string) $this->option('tenant'));
        $requestId = (string) $this->argument('request');
        $status = strtoupper((string) $this->option('status'));

        if (! $statuses->get($tenant->id, $requestId)) {
            $this->components->error("No status document for [{$requestId}] in tenant [{$tenant->id}].");

            return self::FAILURE;
        }

        $statuses->put($tenant->id, $requestId, $this->fields($status, $requestId, $tenant->database));

        $this->components->info("Request [{$requestId}] -> {$status} (tenant {$tenant->id})");

        return self::SUCCESS;
    }

    /** @return array<string, mixed> */
    private function fields(string $status, string $requestId, string $database): array
    {
        $now = gmdate('Y-m-d\TH:i:s\Z');
        $worker = 'dev-stub-worker';

        if ($status === RequestStatus::PROCESSING) {
            return [
                'status' => RequestStatus::PROCESSING,
                'worker' => $worker,
                'subscription' => 'dev-stub',
                'delivery_attempt' => 1,
                'queue_lag_ms' => 42,
                'started_at' => $now,
            ];
        }

        if ($status === RequestStatus::FAILED) {
            return [
                'status' => RequestStatus::FAILED,
                'worker' => $worker,
                'error' => (string) ($this->option('error') ?: 'Synthetic failure from dev:advance-request.'),
                'delivery_attempt' => 1,
                'failed_at' => $now,
            ];
        }

        $common = [
            'status' => RequestStatus::COMPLETED,
            'worker' => $worker,
            'processed_by' => $worker,
            'delivery_attempt' => 1,
            'duration_ms' => 128,
            'completed_at' => $now,
            'currency' => 'USD',
        ];

        if ($this->option('kind') === 'sales') {
            return $common + [
                'rows_received' => 3,
                'rows_written' => 3,
                'total_amount' => 10149.49,
                'result_location' => $database.'.sales_records',
                'unmatched_rep_emails' => ['nobody@example.test'],
                'warning' => 'some rows were stored without an employee link',
            ];
        }

        return $common + [
            'payroll_run_id' => 0,
            'employee_count' => 23,
            'gross_total' => 63120.55,
            'commission_total' => 1420.00,
            'tax_total' => 14199.02,
            'net_total' => 50341.53,
            'paid_days' => 15,
            'result_location' => $database.'.payroll_runs',
            'notes' => 'Written by dev:advance-request; no rows were committed.',
        ];
    }
}
