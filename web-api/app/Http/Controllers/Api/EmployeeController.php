<?php

namespace App\Http\Controllers\Api;

use App\Auth\Ability;
use App\Http\Controllers\Controller;
use App\Models\Employee;
use App\Tenancy\TenantManager;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Gate;

/**
 * Request type 4 (sync): read the tenant's workforce.
 *
 * Served from Cloud SQL through the Cloud SQL Auth Proxy sidecar and cached in
 * Memorystore. The cache key is namespaced per tenant by TenantManager, so one
 * tenant can never be served another tenant's rows.
 */
class EmployeeController extends Controller
{
    private const CACHE_TTL_SECONDS = 60;

    public function __construct(private readonly TenantManager $tenants)
    {
    }

    public function index(Request $request): JsonResponse
    {
        // Salary and commission are a separate ability from "list employees".
        $withCompensation = Gate::allows(Ability::EMPLOYEES_VIEW_COMPENSATION);

        $filters = [
            'department' => $request->string('department')->toString(),
            'active' => $request->has('active') ? $request->boolean('active') : null,
            'per_page' => min(max((int) $request->integer('per_page', 25), 1), 200),
            'page' => max((int) $request->integer('page', 1), 1),
        ];

        /*
         * The compensation flag is part of the cache key.
         *
         * Without it, an admin's cached payload (salaries included) would be served
         * to a viewer for the next 60 seconds. Caching a response whose *shape*
         * depends on the caller's permissions, under a key that ignores those
         * permissions, is a quiet way to leak data across roles.
         */
        $cacheKey = 'employees:'.md5(json_encode($filters + ['comp' => $withCompensation]));

        $payload = Cache::remember($cacheKey, self::CACHE_TTL_SECONDS, function () use ($filters, $withCompensation) {
            $columns = ['id', 'employee_code', 'first_name', 'last_name', 'email', 'department', 'is_active'];

            if ($withCompensation) {
                $columns[] = 'base_salary';
                $columns[] = 'commission_rate';
            }

            $employees = Employee::query()
                ->select($columns)
                ->when($filters['department'] !== '', fn ($q) => $q->where('department', $filters['department']))
                ->when($filters['active'] !== null, fn ($q) => $q->where('is_active', $filters['active']))
                ->orderBy('employee_code')
                ->paginate(perPage: $filters['per_page'], page: $filters['page']);

            return $employees->toArray();
        });

        return response()->json($payload + [
            'meta' => [
                'tenant' => $this->tenants->currentOrFail()->id,
                'cache_ttl_seconds' => self::CACHE_TTL_SECONDS,
                // Tells the SPA to render the salary columns rather than guess.
                'includes_compensation' => $withCompensation,
            ],
        ]);
    }
}
