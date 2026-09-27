<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Http\Middleware\EnsureSessionTenant;
use App\Services\Audit\AuditLogger;
use App\Tenancy\TenantManager;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Validation\ValidationException;

/**
 * Session (cookie) authentication for the first-party React SPA.
 *
 * Cookies rather than bearer tokens, because:
 *   - the SPA is same-origin with the API, so there is nothing to configure;
 *   - the cookie is HttpOnly, so an XSS cannot read the credential;
 *   - sessions already live in Memorystore, so web pods stay stateless.
 *
 * Users live in the tenant schema, so the tenant must already be resolved when
 * these actions run. ResolveTenant sits ahead of the session middleware in the
 * "api" group to guarantee that.
 */
class AuthController extends Controller
{
    public function __construct(
        private readonly TenantManager $tenants,
        private readonly AuditLogger $audit,
    ) {
    }

    public function login(Request $request): JsonResponse
    {
        $credentials = $request->validate([
            'email' => ['required', 'email'],
            'password' => ['required', 'string'],
            'remember' => ['sometimes', 'boolean'],
        ]);

        if (! Auth::attempt(
            ['email' => $credentials['email'], 'password' => $credentials['password']],
            (bool) ($credentials['remember'] ?? false)
        )) {
            // Failed attempts are audited: a burst of these against one account is
            // the signal for credential stuffing.
            $this->audit->record($request, AuditLogger::LOGIN_FAILED, [
                'reason' => 'invalid_credentials',
            ], outcome: 'denied');

            // One generic message: distinguishing "no such user" from "wrong
            // password" tells an attacker which emails are registered.
            throw ValidationException::withMessages([
                'email' => ['These credentials do not match our records.'],
            ]);
        }

        $user = $request->user();

        // A deactivated user must not get a session, even with correct credentials.
        if ($user->is_active === false) {
            Auth::guard('web')->logout();

            $this->audit->record($request, AuditLogger::LOGIN_FAILED, [
                'reason' => 'account_deactivated',
            ], outcome: 'denied');

            throw ValidationException::withMessages([
                'email' => ['This account has been deactivated.'],
            ]);
        }

        // Defeats session fixation: the pre-login session id can no longer be used
        // to ride the authenticated session.
        $request->session()->regenerate();

        // Stamp the tenant onto the session. EnsureSessionTenant verifies this on
        // every subsequent request, so an authenticated session can never be
        // replayed against a different tenant.
        $request->session()->put(
            EnsureSessionTenant::SESSION_KEY,
            $this->tenants->currentOrFail()->id
        );

        $this->audit->record($request, AuditLogger::LOGIN_SUCCEEDED);

        return response()->json(['data' => $this->userPayload($request)]);
    }

    public function logout(Request $request): JsonResponse
    {
        $this->audit->record($request, AuditLogger::LOGOUT);

        Auth::guard('web')->logout();

        $request->session()->invalidate();
        $request->session()->regenerateToken();

        return response()->json(['data' => ['message' => 'Signed out.']]);
    }

    public function user(Request $request): JsonResponse
    {
        return response()->json(['data' => $this->userPayload($request)]);
    }

    /** @return array<string, mixed> */
    private function userPayload(Request $request): array
    {
        $user = $request->user();

        return [
            'id' => $user->id,
            'name' => $user->name,
            'email' => $user->email,
            'role' => $user->role,
            /*
             * The resolved ability list, not the role name.
             *
             * The SPA hides what the API would refuse, and it should not have to
             * reimplement the role matrix to know what that is. Sending abilities
             * means the two can never disagree - the server stays the only place
             * authorisation is decided.
             */
            'abilities' => $user->abilities(),
            'tenant' => $this->tenants->currentOrFail(),
        ];
    }
}
