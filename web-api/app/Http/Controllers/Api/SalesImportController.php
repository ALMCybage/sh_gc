<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Http\Requests\ImportSalesRequest;
use App\Models\SalesRecord;
use App\Services\Audit\AuditLogger;
use App\Services\Messaging\AsyncCommandBus;
use App\Services\PubSub\PublishFailedException;
use App\Tenancy\TenantManager;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Request type 2 (async): bulk sales import.
 *
 * Published to the `sales-import` topic; the Go worker upserts the rows into the
 * tenant schema, keyed on external_id so redeliveries are harmless.
 */
class SalesImportController extends Controller
{
    public function __construct(
        private readonly AsyncCommandBus $bus,
        private readonly TenantManager $tenants,
        private readonly AuditLogger $audit,
    ) {
    }

    public function store(ImportSalesRequest $request): JsonResponse
    {
        $payload = $request->payload();
        $total = round(array_sum(array_column($payload['rows'], 'amount')), 2);

        try {
            $result = $this->bus->dispatch(
                request: $request,
                eventType: 'sales.import.requested',
                topic: (string) config('gcp.pubsub.topics.sales'),
                payload: $payload,
                summary: [
                    'source' => $payload['source'],
                    'row_count' => count($payload['rows']),
                    'total_amount' => $total,
                ],
            );
        } catch (PublishFailedException $e) {
            $this->audit->record($request, AuditLogger::SALES_IMPORT_REQUESTED, [
                'source' => $payload['source'],
                'row_count' => count($payload['rows']),
                'error' => $e->getMessage(),
            ], outcome: 'failed');

            return response()->json([
                'message' => 'Sales import could not be queued. Please retry.',
                'error' => $e->getMessage(),
            ], 503);
        }

        $this->audit->record(
            request: $request,
            action: AuditLogger::SALES_IMPORT_REQUESTED,
            context: [
                'source' => $payload['source'],
                'row_count' => count($payload['rows']),
                'total_amount' => $total,
            ],
            subjectType: 'sales_import',
            subjectId: $result['request_id'],
            requestId: $result['request_id'],
        );

        return response()->json([
            'data' => $result + [
                'tenant' => $this->tenants->currentOrFail()->id,
                'row_count' => count($payload['rows']),
                'status_url' => url("/api/v1/requests/{$result['request_id']}"),
            ],
        ], 202);
    }

    public function index(Request $request): JsonResponse
    {
        $records = SalesRecord::query()
            ->when($request->filled('request_id'), fn ($q) => $q->where('request_id', $request->string('request_id')))
            ->when($request->filled('rep_email'), fn ($q) => $q->where('rep_email', $request->string('rep_email')))
            ->orderByDesc('sold_at')
            ->paginate(perPage: min((int) $request->integer('per_page', 25), 200));

        return response()->json($records);
    }
}
