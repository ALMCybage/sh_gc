<?php

namespace App\Http\Controllers;

use App\Services\Status\StatusStore;
use App\Tenancy\TenantManager;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Throwable;

class HealthController extends Controller
{
    public function __construct(
        private readonly TenantManager $tenants,
        private readonly StatusStore $statuses,
    ) {
    }

    /**
     * Liveness. Deliberately dependency-free: a Redis blip must not make the
     * kubelet restart an otherwise healthy pod.
     */
    public function live(): JsonResponse
    {
        return response()->json([
            'status' => 'ok',
            'service' => config('app.name'),
            'pod' => gethostname(),
            'time' => gmdate('c'),
        ]);
    }

    /**
     * Readiness. Also the target of the GKE BackendConfig health check, so a pod
     * that cannot reach Cloud SQL is pulled out of the NEG instead of serving
     * 500s through the load balancer.
     */
    public function ready(): JsonResponse
    {
        $checks = [
            'mysql' => $this->check(fn () => DB::connection($this->tenants->connectionName())->select('select 1')),
            'redis' => $this->check(fn () => Cache::put('readyz', 1, 5)),
            'firestore' => $this->check(fn () => $this->statuses->ping()),
        ];

        $healthy = ! in_array(false, array_column($checks, 'ok'), true);

        return response()->json([
            'status' => $healthy ? 'ready' : 'degraded',
            'pod' => gethostname(),
            'tenant' => $this->tenants->current()?->id,
            'checks' => $checks,
        ], $healthy ? 200 : 503);
    }

    /** @return array{ok: bool, error?: string} */
    private function check(callable $probe): array
    {
        try {
            $result = $probe();

            return ['ok' => $result === null || $result !== false];
        } catch (Throwable $e) {
            return ['ok' => false, 'error' => $e->getMessage()];
        }
    }
}
