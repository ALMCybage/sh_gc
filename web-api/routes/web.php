<?php

use App\Http\Controllers\HealthController;
use Illuminate\Support\Facades\Route;

/*
| Probe + discovery endpoints. Kept out of the /api prefix so the load balancer
| health check does not need a tenant Host header.
*/

Route::get('/healthz', [HealthController::class, 'live']);
Route::get('/readyz', [HealthController::class, 'ready'])->middleware('tenant');

Route::get('/', fn () => response()->json([
    'service' => config('app.name'),
    'component' => 'stateless-core-web-api',
    'runtime' => 'php-'.PHP_VERSION.' / laravel-'.app()->version(),
    'endpoints' => [
        'POST /api/v1/payroll/calculations' => 'async -> pubsub:'.config('gcp.pubsub.topics.payroll'),
        'POST /api/v1/sales/imports' => 'async -> pubsub:'.config('gcp.pubsub.topics.sales'),
        'GET  /api/v1/requests/{id}' => 'sync -> firestore',
        'GET  /api/v1/employees' => 'sync -> cloudsql + memorystore',
    ],
]));
