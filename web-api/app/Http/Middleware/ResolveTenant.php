<?php

namespace App\Http\Middleware;

use App\Tenancy\TenantManager;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpFoundation\Response;

/**
 * The "TenancyForLaravel" step from the architecture diagram: every request is
 * pinned to one tenant schema before it reaches a controller.
 */
class ResolveTenant
{
    public function __construct(private readonly TenantManager $tenants)
    {
    }

    public function handle(Request $request, Closure $next): Response
    {
        $tenant = $this->tenants->setCurrent(
            $this->tenants->resolveFromRequest($request)
        );

        Log::withContext([
            'tenant_id' => $tenant->id,
            'tenant_db' => $tenant->database,
        ]);

        /** @var Response $response */
        $response = $next($request);

        $response->headers->set('X-Tenant-Id', $tenant->id);

        return $response;
    }
}
