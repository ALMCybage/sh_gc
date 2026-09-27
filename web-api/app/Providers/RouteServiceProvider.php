<?php

namespace App\Providers;

use App\Tenancy\TenantManager;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Foundation\Support\Providers\RouteServiceProvider as ServiceProvider;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Str;

class RouteServiceProvider extends ServiceProvider
{
    public const HOME = '/home';

    public function boot(): void
    {
        $this->configureRateLimiting();

        $this->routes(function () {
            Route::prefix('api')
                ->middleware('api')
                ->group(base_path('routes/api.php'));

            // Probe + discovery routes run outside the "web" group on purpose:
            // no sessions, no cookies, no CSRF. Liveness must not depend on Redis.
            Route::middleware('probe')
                ->group(base_path('routes/web.php'));
        });
    }

    protected function configureRateLimiting(): void
    {
        /*
         * Multi-tenant rate limiting: buckets are per tenant + per client IP, so
         * one noisy tenant cannot exhaust another tenant's budget. Behind the GCP
         * load balancer the client IP comes from X-Forwarded-For, which
         * TrustProxies unwraps.
         */
        RateLimiter::for('api', function (Request $request) {
            $tenants = app(TenantManager::class);

            // Throttling runs before ResolveTenant, so derive the bucket key
            // straight from the request without failing on unknown tenants.
            $tenant = $tenants->current()?->id
                ?? $request->header((string) config('tenancy.header'))
                ?? $tenants->tenantIdFromHost($request->getHost())
                ?? 'unresolved';

            return [
                Limit::perMinute((int) config('app.rate_limit_per_tenant', 600))->by('tenant:'.$tenant),
                Limit::perMinute((int) config('app.rate_limit_per_client', 120))->by('client:'.$tenant.':'.$request->ip()),
            ];
        });

        /*
         * Login is keyed on tenant + email + IP rather than IP alone, so a shared
         * office NAT cannot lock out a whole tenant, while a distributed attempt
         * against one account still hits the same bucket.
         */
        RateLimiter::for('login', function (Request $request) {
            $tenant = app(TenantManager::class)->current()?->id ?? 'unresolved';
            $email = Str::lower((string) $request->input('email'));

            return [
                Limit::perMinute(5)->by('login:'.$tenant.':'.$email),
                Limit::perMinute(20)->by('login-ip:'.$tenant.':'.$request->ip()),
            ];
        });
    }
}
