<?php

namespace App\Services\Google;

use Google\Auth\ApplicationDefaultCredentials;
use Google\Auth\FetchAuthTokenInterface;
use Illuminate\Support\Facades\Log;
use Throwable;

/**
 * Mints Google OAuth access tokens from Application Default Credentials.
 *
 * On GKE this resolves through Workload Identity (the GKE metadata server), so
 * no service-account key file ever lands in the image. Locally it falls back to
 * GOOGLE_APPLICATION_CREDENTIALS or gcloud user credentials.
 *
 * Tokens are cached in-process; a php-fpm worker handles many requests, so this
 * avoids a metadata round-trip per publish.
 */
class AccessTokenProvider
{
    private ?FetchAuthTokenInterface $credentials = null;

    private ?string $token = null;

    private int $expiresAt = 0;

    /** @param array<int, string> $scopes */
    public function __construct(private readonly array $scopes)
    {
    }

    public function token(): string
    {
        if ($this->token !== null && time() < $this->expiresAt) {
            return $this->token;
        }

        $fetched = $this->credentials()->fetchAuthToken();

        if (empty($fetched['access_token'])) {
            throw new GoogleAuthException('Application Default Credentials returned no access token.');
        }

        $this->token = (string) $fetched['access_token'];
        // Refresh a minute early to stay clear of clock skew.
        $this->expiresAt = time() + max(60, (int) ($fetched['expires_in'] ?? 3600)) - 60;

        return $this->token;
    }

    private function credentials(): FetchAuthTokenInterface
    {
        if ($this->credentials !== null) {
            return $this->credentials;
        }

        try {
            return $this->credentials = ApplicationDefaultCredentials::getCredentials($this->scopes);
        } catch (Throwable $e) {
            Log::error('Unable to load Application Default Credentials.', ['error' => $e->getMessage()]);

            throw new GoogleAuthException($e->getMessage(), 0, $e);
        }
    }
}
