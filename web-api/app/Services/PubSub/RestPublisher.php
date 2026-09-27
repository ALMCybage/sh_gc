<?php

namespace App\Services\PubSub;

use App\Services\Google\AccessTokenProvider;
use GuzzleHttp\Client;
use GuzzleHttp\Exception\GuzzleException;
use Illuminate\Support\Facades\Log;
use Throwable;

/**
 * Publishes to Google Cloud Pub/Sub over the v1 REST API.
 *
 * REST (rather than the gRPC client) keeps the PHP image free of the grpc/protobuf
 * extensions, which shrinks the container and the cold-start time - the web tier
 * only needs fire-and-forget publishes, not streaming pulls.
 *
 * Set PUBSUB_EMULATOR_HOST to point at the local emulator; auth is then skipped.
 */
class RestPublisher implements Publisher
{
    public function __construct(
        private readonly Client $http,
        private readonly AccessTokenProvider $tokens,
        private readonly string $projectId,
        private readonly ?string $emulatorHost = null,
    ) {
    }

    public function publish(string $topic, array $payload, array $attributes = []): string
    {
        $url = sprintf(
            '%s/v1/projects/%s/topics/%s:publish',
            $this->baseUri(),
            rawurlencode($this->projectId),
            rawurlencode($topic),
        );

        $body = [
            'messages' => [
                [
                    'data' => base64_encode(json_encode($payload, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES)),
                    'attributes' => array_map(static fn ($v) => (string) $v, $attributes),
                ],
            ],
        ];

        try {
            $response = $this->http->post($url, [
                'headers' => $this->headers(),
                'json' => $body,
            ]);

            $decoded = json_decode((string) $response->getBody(), true, 512, JSON_THROW_ON_ERROR);
            $messageId = $decoded['messageIds'][0] ?? null;

            if (! $messageId) {
                throw new PublishFailedException("Pub/Sub accepted the request but returned no message id for topic [{$topic}].");
            }

            return (string) $messageId;
        } catch (GuzzleException|Throwable $e) {
            if ($e instanceof PublishFailedException) {
                throw $e;
            }

            Log::error('Pub/Sub publish failed.', [
                'topic' => $topic,
                'error' => $e->getMessage(),
            ]);

            throw new PublishFailedException("Failed to publish to [{$topic}]: {$e->getMessage()}", 0, $e);
        }
    }

    private function baseUri(): string
    {
        if ($this->emulatorHost) {
            return str_starts_with($this->emulatorHost, 'http')
                ? rtrim($this->emulatorHost, '/')
                : 'http://'.rtrim($this->emulatorHost, '/');
        }

        return 'https://pubsub.googleapis.com';
    }

    /** @return array<string, string> */
    private function headers(): array
    {
        $headers = ['Content-Type' => 'application/json'];

        if (! $this->emulatorHost) {
            $headers['Authorization'] = 'Bearer '.$this->tokens->token();
        }

        return $headers;
    }
}
