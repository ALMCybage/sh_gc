<?php

namespace App\Services\Audit;

use App\Models\AuditLog;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Throwable;

/**
 * Writes the tenant's audit trail.
 *
 * Two rules shape this class:
 *
 *  1. It never throws. An audit write failing must not fail the user's request -
 *     but it must be loud in the application log, because a silently missing
 *     audit trail is worse than a failed request.
 *  2. It records parameters, never payloads. "imported 2,000 rows from crm" is
 *     auditable; the rows themselves are business data that already lives in
 *     sales_records and would bloat the trail.
 */
class AuditLogger
{
    public const PAYROLL_REQUESTED = 'payroll.requested';
    public const SALES_IMPORT_REQUESTED = 'sales_import.requested';
    public const LOGIN_SUCCEEDED = 'auth.login.succeeded';
    public const LOGIN_FAILED = 'auth.login.failed';
    public const LOGOUT = 'auth.logout';
    public const AUTHORIZATION_DENIED = 'authorization.denied';
    public const SESSION_TENANT_MISMATCH = 'security.session_tenant_mismatch';

    /**
     * @param  array<string, mixed>  $context
     */
    public function record(
        Request $request,
        string $action,
        array $context = [],
        ?string $subjectType = null,
        ?string $subjectId = null,
        ?string $requestId = null,
        string $outcome = 'success',
    ): void {
        $user = $request->user();

        try {
            AuditLog::query()->create([
                'actor_id' => $user?->id,
                'actor_email' => $user?->email ?? $this->attemptedEmail($request),
                'actor_role' => $user?->role,
                'action' => $action,
                'subject_type' => $subjectType,
                'subject_id' => $subjectId,
                'request_id' => $requestId,
                'trace_id' => $this->traceId($request),
                'ip' => $request->ip(),
                'user_agent' => Str::limit((string) $request->userAgent(), 250, ''),
                'outcome' => $outcome,
                'context' => $context,
            ]);
        } catch (Throwable $e) {
            // Loud, but non-fatal. If audit writes are failing that is an incident
            // in its own right and this is what surfaces it.
            Log::error('AUDIT WRITE FAILED', [
                'action' => $action,
                'actor' => $user?->email,
                'error' => $e->getMessage(),
            ]);
        }
    }

    /**
     * On a failed login there is no authenticated user, but the attempted
     * identity is exactly what an investigator needs.
     */
    private function attemptedEmail(Request $request): ?string
    {
        $email = $request->input('email');

        return is_string($email) ? Str::limit(Str::lower($email), 180, '') : null;
    }

    private function traceId(Request $request): ?string
    {
        $header = $request->header('X-Cloud-Trace-Context');
        if (! $header) {
            return null;
        }

        // Format is TRACE_ID/SPAN_ID;o=TRACE_TRUE
        return Str::limit(Str::before((string) $header, '/'), 120, '');
    }
}
