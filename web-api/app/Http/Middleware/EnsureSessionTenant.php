<?php

namespace App\Http\Middleware;

use App\Tenancy\TenantManager;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpFoundation\Response;

/**
 * Binds a session to the tenant it was created for.
 *
 * Why this exists as an explicit control:
 *
 * Tenants are separated by hostname, and the session cookie is host-only and
 * named per tenant, so in normal operation a session cannot travel between
 * tenants. But that isolation is *implicit* - it falls out of cookie scoping
 * rather than from any check. One config change (a shared SESSION_DOMAIN, a
 * reverted cookie name, a future path-based tenant scheme) would silently turn it
 * off, and the failure mode is severe: user id 1 exists in every tenant schema
 * and is a different real person in each, so an accepted cross-tenant session
 * means acting as somebody else entirely.
 *
 * So the tenant is written into the session payload at login and verified here on
 * every request. A mismatch destroys the session rather than trusting it.
 *
 * Runs after the session middleware and before the auth guard.
 */
class EnsureSessionTenant
{
    public const SESSION_KEY = 'tenant_id';

    public function __construct(private readonly TenantManager $tenants)
    {
    }

    public function handle(Request $request, Closure $next): Response
    {
        if (! $request->hasSession()) {
            return $next($request);
        }

        $session = $request->session();
        $bound = $session->get(self::SESSION_KEY);
        $current = $this->tenants->currentOrFail();

        // No tenant recorded yet: a pre-login session (the CSRF cookie request,
        // for example). Stamp it so the very next request is checked.
        if ($bound === null) {
            $session->put(self::SESSION_KEY, $current->id);

            return $next($request);
        }

        if ($bound === $current->id) {
            return $next($request);
        }

        Log::warning('Session/tenant mismatch; destroying the session.', [
            'session_tenant' => $bound,
            'request_tenant' => $current->id,
            'ip' => $request->ip(),
            'path' => $request->path(),
        ]);

        Auth::guard('web')->logout();
        $session->flush();
        $session->invalidate();
        $session->regenerateToken();

        return response()->json([
            'message' => 'Your session does not belong to this tenant. Please sign in again.',
        ], 401);
    }
}
