<?php

namespace App\Http;

use Illuminate\Foundation\Http\Kernel as HttpKernel;

class Kernel extends HttpKernel
{
    /**
     * The application's global HTTP middleware stack.
     *
     * @var array<int, class-string|string>
     */
    protected $middleware = [
        // Behind the GCP external HTTPS load balancer every request arrives with
        // X-Forwarded-For / X-Forwarded-Proto set by the edge.
        \App\Http\Middleware\TrustProxies::class,
        \Fruitcake\Cors\HandleCors::class,
        \App\Http\Middleware\PreventRequestsDuringMaintenance::class,
        \Illuminate\Foundation\Http\Middleware\ValidatePostSize::class,
        \App\Http\Middleware\TrimStrings::class,
        \Illuminate\Foundation\Http\Middleware\ConvertEmptyStringsToNull::class,
    ];

    /**
     * The application's route middleware groups.
     *
     * @var array<string, array<int, class-string|string>>
     */
    protected $middlewareGroups = [
        /*
         * Only Sanctum's /sanctum/csrf-cookie route uses this group. ResolveTenant
         * has to be here too: without it that route would start a session under
         * the default cookie name, and the CSRF token it hands out would belong to
         * a different session than the one the /api routes use, so every write
         * would fail with a 419.
         */
        'web' => [
            \App\Http\Middleware\ResolveTenant::class,
            \App\Http\Middleware\EncryptCookies::class,
            \Illuminate\Cookie\Middleware\AddQueuedCookiesToResponse::class,
            \Illuminate\Session\Middleware\StartSession::class,
            \App\Http\Middleware\EnsureSessionTenant::class,
            \Illuminate\View\Middleware\ShareErrorsFromSession::class,
            \App\Http\Middleware\VerifyCsrfToken::class,
            \Illuminate\Routing\Middleware\SubstituteBindings::class,
        ],

        /*
         * Order matters here.
         *
         * ResolveTenant runs before Sanctum's stateful middleware because that
         * middleware starts the session, and the tenant determines both the
         * session cookie name and the schema the auth provider queries. Resolve
         * late and you would authenticate against the wrong tenant's users table.
         */
        'api' => [
            \App\Http\Middleware\ForceJsonResponse::class,
            \App\Http\Middleware\ResolveTenant::class,
            \Laravel\Sanctum\Http\Middleware\EnsureFrontendRequestsAreStateful::class,
            // After the session exists, before the auth guard: refuses to carry a
            // session from one tenant into another.
            \App\Http\Middleware\EnsureSessionTenant::class,
            'throttle:api',
            \Illuminate\Routing\Middleware\SubstituteBindings::class,
        ],

        /*
         * Health/discovery endpoints. No session, no cookies, no CSRF, so a
         * Memorystore hiccup cannot fail a liveness probe.
         */
        'probe' => [
            \App\Http\Middleware\ForceJsonResponse::class,
        ],
    ];

    /**
     * The application's route middleware.
     *
     * @var array<string, class-string|string>
     */
    protected $routeMiddleware = [
        'auth' => \App\Http\Middleware\Authenticate::class,
        'auth.basic' => \Illuminate\Auth\Middleware\AuthenticateWithBasicAuth::class,
        'cache.headers' => \Illuminate\Http\Middleware\SetCacheHeaders::class,
        'can' => \Illuminate\Auth\Middleware\Authorize::class,
        'guest' => \App\Http\Middleware\RedirectIfAuthenticated::class,
        'password.confirm' => \Illuminate\Auth\Middleware\RequirePassword::class,
        'idempotent' => \App\Http\Middleware\EnforceIdempotency::class,
        'signed' => \Illuminate\Routing\Middleware\ValidateSignature::class,
        'tenant' => \App\Http\Middleware\ResolveTenant::class,
        'throttle' => \Illuminate\Routing\Middleware\ThrottleRequests::class,
        'verified' => \Illuminate\Auth\Middleware\EnsureEmailIsVerified::class,
    ];
}
