<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Http\Requests\CalculatePayrollRequest;
use App\Models\PayrollRun;
use App\Services\Audit\AuditLogger;
use App\Services\Messaging\AsyncCommandBus;
use App\Services\PubSub\PublishFailedException;
use App\Tenancy\TenantManager;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Request type 1 (async): kick off a payroll calculation.
 *
 * The web pod validates, publishes to `payroll-calc-events` and returns 202. All
 * the arithmetic happens in the Go worker pool.
 */
class PayrollController extends Controller
{
    public function __construct(
        private readonly AsyncCommandBus $bus,
        private readonly TenantManager $tenants,
        private readonly AuditLogger $audit,
    ) {
    }

    public function store(CalculatePayrollRequest $request): JsonResponse
    {
        $payload = $request->payload();

        try {
            $result = $this->bus->dispatch(
                request: $request,
                eventType: 'payroll.calculate.requested',
                topic: (string) config('gcp.pubsub.topics.payroll'),
                payload: $payload,
                summary: [
                    'period_start' => $payload['period_start'],
                    'period_end' => $payload['period_end'],
                    'employee_scope' => $payload['employee_ids'] === [] ? 'all-active' : 'explicit',
                    'employee_count_requested' => count($payload['employee_ids']),
                ],
            );
        } catch (PublishFailedException $e) {
            // Audited as a failure too: "someone tried to run payroll and the
            // platform refused" is exactly what you want on record.
            $this->audit->record($request, AuditLogger::PAYROLL_REQUESTED, [
                'period_start' => $payload['period_start'],
                'period_end' => $payload['period_end'],
                'error' => $e->getMessage(),
            ], outcome: 'failed');

            return response()->json([
                'message' => 'Payroll request could not be queued. Please retry.',
                'error' => $e->getMessage(),
            ], 503);
        }

        $this->audit->record(
            request: $request,
            action: AuditLogger::PAYROLL_REQUESTED,
            context: [
                'period_start' => $payload['period_start'],
                'period_end' => $payload['period_end'],
                'tax_rate' => $payload['tax_rate'],
                'include_commission' => $payload['include_commission'],
                'employee_count_requested' => count($payload['employee_ids']),
            ],
            subjectType: 'payroll_run',
            subjectId: $result['request_id'],
            requestId: $result['request_id'],
        );

        return response()->json([
            'data' => $result + [
                'tenant' => $this->tenants->currentOrFail()->id,
                'status_url' => url("/api/v1/requests/{$result['request_id']}"),
            ],
        ], 202);
    }

    /**
     * Read side: the rows the Go worker committed to Cloud SQL.
     */
    public function index(Request $request): JsonResponse
    {
        $runs = PayrollRun::query()
            ->when($request->filled('status'), fn ($q) => $q->where('status', $request->string('status')))
            ->orderByDesc('id')
            ->paginate(perPage: min((int) $request->integer('per_page', 15), 100));

        return response()->json($runs);
    }

    public function show(string $requestId): JsonResponse
    {
        $run = PayrollRun::query()
            ->with('lines.employee:id,employee_code,first_name,last_name,department')
            ->where('request_id', $requestId)
            ->first();

        if (! $run) {
            return response()->json([
                'message' => 'No payroll run has been committed for this request id yet.',
                'hint' => "Poll /api/v1/requests/{$requestId} for the async status.",
            ], 404);
        }

        return response()->json(['data' => $run]);
    }
}
