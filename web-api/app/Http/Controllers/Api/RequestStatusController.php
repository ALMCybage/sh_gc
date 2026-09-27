<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Services\Status\RequestStatus;
use App\Services\Status\StatusStore;
use App\Tenancy\TenantManager;
use Illuminate\Http\JsonResponse;

/**
 * Request type 3 (sync): poll the status of an async request.
 *
 * Reads straight from Firestore, so it never touches Cloud SQL and never
 * competes with the worker pool for connections.
 */
class RequestStatusController extends Controller
{
    public function __construct(
        private readonly StatusStore $statuses,
        private readonly TenantManager $tenants,
    ) {
    }

    public function show(string $requestId): JsonResponse
    {
        $tenant = $this->tenants->currentOrFail();

        $status = $this->statuses->get($tenant->id, $requestId);

        if ($status === null) {
            return response()->json([
                'message' => 'Unknown request id for this tenant.',
                'request_id' => $requestId,
                'tenant' => $tenant->id,
            ], 404);
        }

        $terminal = in_array($status['status'] ?? null, [RequestStatus::COMPLETED, RequestStatus::FAILED], true);

        return response()->json([
            'data' => $status,
            'meta' => [
                'terminal' => $terminal,
                'retry_after_seconds' => $terminal ? null : 2,
            ],
        ], 200, $terminal ? [] : ['Retry-After' => '2']);
    }
}
