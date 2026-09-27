<?php

namespace App\Http\Middleware;

use App\Services\Idempotency\IdempotencyStore;
use App\Tenancy\TenantManager;
use Closure;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpFoundation\Response;

/**
 * Requires an Idempotency-Key on the async write endpoints and replays the stored
 * response when a key is reused.
 *
 * The key is mandatory rather than optional. An optional guard protects only the
 * clients that remember to opt in, and the failure it prevents here - two payroll
 * runs for the same period because a request was retried - is exactly the kind of
 * bug that shows up in production and not in testing.
 */
class EnforceIdempotency
{
    private const MIN_LENGTH = 8;
    private const MAX_LENGTH = 255;

    public function __construct(
        private readonly IdempotencyStore $store,
        private readonly TenantManager $tenants,
    ) {
    }

    public function handle(Request $request, Closure $next): Response
    {
        $key = trim((string) $request->header('Idempotency-Key'));

        if ($key === '') {
            return response()->json([
                'message' => 'This endpoint requires an Idempotency-Key header.',
                'detail' => 'Send a stable, unique value per logical operation (a UUID is fine). '
                    .'Retrying with the same key replays the original response instead of starting the work twice.',
            ], 400);
        }

        if (strlen($key) < self::MIN_LENGTH || strlen($key) > self::MAX_LENGTH) {
            return response()->json([
                'message' => sprintf(
                    'Idempotency-Key must be between %d and %d characters.',
                    self::MIN_LENGTH,
                    self::MAX_LENGTH
                ),
            ], 400);
        }

        $tenantId = $this->tenants->currentOrFail()->id;
        $payload = $request->all();

        $claim = $this->store->claim($tenantId, $key, $payload);

        if ($claim !== null) {
            return $this->respondToExistingClaim($claim, $key, $tenantId);
        }

        $response = $next($request);

        // Only successful responses are recorded. A 422 should be retryable with
        // the same key once the client fixes the payload... except the fingerprint
        // will then differ, so the claim is released on any non-2xx instead.
        if ($response->getStatusCode() >= 200 && $response->getStatusCode() < 300) {
            $this->store->complete($tenantId, $key, $payload, [
                'status' => $response->getStatusCode(),
                'body' => $this->decode($response),
            ]);
        } else {
            $this->store->release($tenantId, $key);
        }

        return $response;
    }

    /**
     * @param  array{state: string, response?: array<string, mixed>}  $claim
     */
    private function respondToExistingClaim(array $claim, string $key, string $tenantId): JsonResponse
    {
        if ($claim['state'] === 'completed') {
            $stored = $claim['response'] ?? [];

            Log::info('Idempotent replay.', ['tenant_id' => $tenantId, 'key_hash' => substr(hash('sha256', $key), 0, 12)]);

            return response()
                ->json($stored['body'] ?? [], (int) ($stored['status'] ?? 200))
                // Lets the client tell a replay from a fresh submission, which
                // matters if it is counting how much work it queued.
                ->header('Idempotency-Replayed', 'true');
        }

        if ($claim['state'] === 'conflict') {
            return response()->json([
                'message' => 'This Idempotency-Key was already used with a different payload.',
                'detail' => 'Use a new key for a new operation. Reusing a key with different data is '
                    .'almost always a client bug, so it is rejected rather than silently accepted.',
            ], 409);
        }

        // in_flight: the first request is still running.
        return response()->json([
            'message' => 'A request with this Idempotency-Key is already in progress.',
            'detail' => 'Poll the status URL from the original response, or retry shortly.',
        ], 409)->header('Retry-After', '2');
    }

    /** @return array<string, mixed> */
    private function decode(Response $response): array
    {
        $decoded = json_decode((string) $response->getContent(), true);

        return is_array($decoded) ? $decoded : [];
    }
}
