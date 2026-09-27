<?php

namespace App\Services\Status;

use App\Services\Google\AccessTokenProvider;
use GuzzleHttp\Client;
use GuzzleHttp\Exception\ClientException;
use Illuminate\Support\Facades\Log;
use Throwable;

/**
 * Firestore-backed request status tracking, over the REST API.
 *
 * Documents are keyed "<tenant_id>__<request_id>" and also carry tenant_id as a
 * field, so the collection is partitioned per tenant and can be queried or
 * secured per tenant. This is the component that replaces the per-pod SQLite
 * file in the legacy architecture, which is what allows the web tier to scale
 * horizontally.
 */
class FirestoreStatusStore implements StatusStore
{
    public function __construct(
        private readonly Client $http,
        private readonly AccessTokenProvider $tokens,
        private readonly string $projectId,
        private readonly string $database,
        private readonly string $collection,
        private readonly ?string $emulatorHost = null,
    ) {
    }

    public function put(string $tenantId, string $requestId, array $fields): void
    {
        $fields = array_merge($fields, [
            'tenant_id' => $tenantId,
            'request_id' => $requestId,
            'updated_at' => gmdate('Y-m-d\TH:i:s\Z'),
        ]);

        // updateMask turns the PATCH into a field-level merge, so the worker's
        // later writes never clobber what the web tier recorded.
        $query = http_build_query([
            'updateMask.fieldPaths' => array_keys($fields),
        ]);
        $query = preg_replace('/updateMask\.fieldPaths%5B\d+%5D/', 'updateMask.fieldPaths', $query);

        try {
            $this->http->patch($this->documentUri($tenantId, $requestId).'?'.$query, [
                'headers' => $this->headers(),
                'json' => ['fields' => FirestoreValue::encodeFields($fields)],
            ]);
        } catch (Throwable $e) {
            // Status tracking is observability, not the source of truth. Never
            // let it fail the caller's request.
            Log::warning('Firestore status write failed.', [
                'tenant_id' => $tenantId,
                'request_id' => $requestId,
                'error' => $e->getMessage(),
            ]);
        }
    }

    public function get(string $tenantId, string $requestId): ?array
    {
        try {
            $response = $this->http->get($this->documentUri($tenantId, $requestId), [
                'headers' => $this->headers(),
            ]);
        } catch (ClientException $e) {
            if ($e->getResponse()->getStatusCode() === 404) {
                return null;
            }

            throw $e;
        }

        $document = json_decode((string) $response->getBody(), true, 512, JSON_THROW_ON_ERROR);

        return FirestoreValue::decodeFields($document['fields'] ?? []);
    }

    public function ping(): bool
    {
        try {
            $this->http->get($this->documentsUri().'?pageSize=1', [
                'headers' => $this->headers(),
            ]);

            return true;
        } catch (ClientException $e) {
            // An empty collection is still a healthy Firestore.
            return $e->getResponse()->getStatusCode() === 404;
        } catch (Throwable) {
            return false;
        }
    }

    private function documentUri(string $tenantId, string $requestId): string
    {
        return $this->documentsUri().'/'.rawurlencode($this->documentId($tenantId, $requestId));
    }

    private function documentsUri(): string
    {
        return sprintf(
            '%s/v1/projects/%s/databases/%s/documents/%s',
            $this->baseUri(),
            rawurlencode($this->projectId),
            rawurlencode($this->database),
            rawurlencode($this->collection),
        );
    }

    private function documentId(string $tenantId, string $requestId): string
    {
        return $tenantId.'__'.$requestId;
    }

    private function baseUri(): string
    {
        if ($this->emulatorHost) {
            return str_starts_with($this->emulatorHost, 'http')
                ? rtrim($this->emulatorHost, '/')
                : 'http://'.rtrim($this->emulatorHost, '/');
        }

        return 'https://firestore.googleapis.com';
    }

    /** @return array<string, string> */
    private function headers(): array
    {
        return [
            'Content-Type' => 'application/json',
            // The emulator accepts (and requires) the literal "owner" token.
            'Authorization' => 'Bearer '.($this->emulatorHost ? 'owner' : $this->tokens->token()),
        ];
    }
}
