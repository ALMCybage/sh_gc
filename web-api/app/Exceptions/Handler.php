<?php

namespace App\Exceptions;

use App\Tenancy\TenantManager;
use App\Tenancy\TenantNotFoundException;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Foundation\Exceptions\Handler as ExceptionHandler;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException;
use Throwable;

class Handler extends ExceptionHandler
{
    /**
     * @var array<int, class-string<Throwable>>
     */
    protected $dontReport = [];

    /**
     * @var array<int, string>
     */
    protected $dontFlash = [
        'current_password',
        'password',
        'password_confirmation',
    ];

    public function register(): void
    {
        $this->renderable(function (TenantNotFoundException $e, Request $request) {
            return response()->json([
                'message' => 'Unknown tenant.',
                'detail' => sprintf(
                    'No tenant matched [%s]. Reach this API on the tenant subdomain.',
                    $e->identifier(),
                ),
            ], 404);
        });

        /*
         * Registered on AccessDeniedHttpException, not AuthorizationException.
         *
         * Laravel's Handler::render() runs prepareException() BEFORE consulting
         * renderable callbacks, and that converts an AuthorizationException without
         * a status into an AccessDeniedHttpException. A callback registered on the
         * original type is therefore never reached - which is easy to miss, because
         * the response is still a 403 and only the body is wrong.
         */
        $this->renderable(function (AccessDeniedHttpException $e, Request $request) {
            return $this->renderDenial($e, $request);
        });

        // Kept for anything that throws AuthorizationException with an explicit
        // status, which prepareException maps to a plain HttpException instead.
        $this->renderable(function (AuthorizationException $e, Request $request) {
            return $this->renderDenial($e, $request);
        });
    }

    private function renderDenial(Throwable $e, Request $request): JsonResponse
    {
        $user = $request->user();

        /*
         * Denials are logged, not just returned. A viewer repeatedly probing
         * POST /payroll/calculations is a signal worth having - either a compromised
         * account or a broken client, and both are worth knowing about.
         */
        Log::warning('Authorization denied.', [
            'actor' => $user?->email,
            'role' => $user?->role,
            'method' => $request->method(),
            'path' => $request->path(),
            'ip' => $request->ip(),
        ]);

        $message = $e->getMessage();
        $generic = $message === '' || $message === 'This action is unauthorized.';

        return response()->json([
            'message' => 'Your role does not permit this action.',
            'detail' => $generic
                ? 'Ask a tenant owner to grant the required permission.'
                : $message,
            'role' => $user?->role,
        ], 403);
    }

    /**
     * Extra context on every logged exception, so Cloud Logging can filter by
     * tenant without the message having to mention it.
     *
     * @return array<string, mixed>
     */
    protected function context(): array
    {
        return array_merge(parent::context(), [
            'tenant_id' => app(TenantManager::class)->current()?->id,
        ]);
    }
}
