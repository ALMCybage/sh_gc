<?php

namespace App\Providers;

use App\Services\Google\AccessTokenProvider;
use App\Services\Idempotency\IdempotencyStore;
use App\Services\PubSub\LogPublisher;
use App\Services\PubSub\Publisher;
use App\Services\PubSub\RestPublisher;
use App\Services\Status\CacheStatusStore;
use App\Services\Status\FirestoreStatusStore;
use App\Services\Status\NullStatusStore;
use App\Services\Status\StatusStore;
use App\Tenancy\TenantManager;
use GuzzleHttp\Client;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\ServiceProvider;
use InvalidArgumentException;

class GcpServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(TenantManager::class);

        $this->app->singleton(AccessTokenProvider::class, fn ($app) => new AccessTokenProvider(
            (array) $app['config']->get('gcp.auth_scopes', [])
        ));

        /*
         * Idempotency claims live in the default cache store, which is Memorystore
         * in production. It has to be a store shared by every web pod: a per-pod
         * store would let two retries land on different pods and both proceed,
         * which is the exact failure this guards against.
         */
        $this->app->singleton(IdempotencyStore::class, fn () => new IdempotencyStore(Cache::store()));

        $this->app->singleton(Publisher::class, function ($app) {
            $config = $app['config']->get('gcp.pubsub');

            return match ($config['driver']) {
                'log' => new LogPublisher(),
                'rest' => new RestPublisher(
                    http: new Client(['timeout' => $config['timeout'], 'http_errors' => true]),
                    tokens: $app->make(AccessTokenProvider::class),
                    projectId: (string) $app['config']->get('gcp.project_id'),
                    emulatorHost: $config['emulator_host'] ?: null,
                ),
                default => throw new InvalidArgumentException("Unsupported PUBSUB_DRIVER [{$config['driver']}]."),
            };
        });

        $this->app->singleton(StatusStore::class, function ($app) {
            $config = $app['config']->get('gcp.firestore');

            return match ($config['driver']) {
                'null' => new NullStatusStore(),
                'cache' => new CacheStatusStore(Cache::store()),
                'rest' => new FirestoreStatusStore(
                    http: new Client(['timeout' => $config['timeout'], 'http_errors' => true]),
                    tokens: $app->make(AccessTokenProvider::class),
                    projectId: (string) $app['config']->get('gcp.project_id'),
                    database: (string) $config['database'],
                    collection: (string) $config['collection'],
                    emulatorHost: $config['emulator_host'] ?: null,
                ),
                default => throw new InvalidArgumentException("Unsupported FIRESTORE_DRIVER [{$config['driver']}]."),
            };
        });
    }
}
