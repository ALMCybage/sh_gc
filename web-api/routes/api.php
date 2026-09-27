<?php

use App\Auth\Ability;
use App\Http\Controllers\Api\AuditController;
use App\Http\Controllers\Api\AuthController;
use App\Http\Controllers\Api\EmployeeController;
use App\Http\Controllers\Api\PayrollController;
use App\Http\Controllers\Api\RequestStatusController;
use App\Http\Controllers\Api\SalesImportController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Tenant-scoped API
|--------------------------------------------------------------------------
|
| Four request types reach this application:
|
|  1. POST /api/v1/payroll/calculations  -> async, Pub/Sub `payroll-calc-events`
|  2. POST /api/v1/sales/imports         -> async, Pub/Sub `sales-import`
|  3. GET  /api/v1/requests/{requestId}  -> sync, reads Firestore
|  4. GET  /api/v1/employees             -> sync, reads Cloud SQL via Memorystore
|
| The tenant is resolved by the "api" middleware group (see App\Http\Kernel),
| before the session starts, so everything below is already schema-scoped.
|
| Authorisation is declared here with `can:` rather than checked inside
| controllers. Keeping it on the route means the permission a route requires is
| visible in `php artisan route:list`, and a new route cannot accidentally ship
| with no check at all.
|
*/

Route::prefix('v1')->group(function () {
    /*
    | Unauthenticated, but still tenant-scoped. The SPA calls whoami before the
    | login screen renders so it can show which tenant the user is signing in to.
    */
    Route::get('/whoami', function (\App\Tenancy\TenantManager $tenants) {
        return response()->json([
            'tenant' => $tenants->currentOrFail(),
            'pod' => gethostname(),
        ]);
    });

    // Tighter bucket than the general API limiter: credential stuffing should run
    // out of attempts long before it runs out of the tenant's budget.
    Route::post('/auth/login', [AuthController::class, 'login'])->middleware('throttle:login');

    Route::middleware('auth:sanctum')->group(function () {
        Route::get('/auth/user', [AuthController::class, 'user']);
        Route::post('/auth/logout', [AuthController::class, 'logout']);

        // 1. async: payroll calculation. The money-moving action, so it needs both
        //    the narrowest ability and an idempotency key.
        Route::post('/payroll/calculations', [PayrollController::class, 'store'])
            ->middleware(['can:'.Ability::PAYROLL_RUN, 'idempotent']);

        Route::get('/payroll/calculations', [PayrollController::class, 'index'])
            ->middleware('can:'.Ability::PAYROLL_VIEW);

        Route::get('/payroll/calculations/{requestId}', [PayrollController::class, 'show'])
            ->middleware('can:'.Ability::PAYROLL_VIEW);

        // 2. async: sales import
        Route::post('/sales/imports', [SalesImportController::class, 'store'])
            ->middleware(['can:'.Ability::SALES_IMPORT, 'idempotent']);

        Route::get('/sales/records', [SalesImportController::class, 'index'])
            ->middleware('can:'.Ability::SALES_VIEW);

        // 3. sync: async request status (Firestore). Any authenticated user may
        //    poll a request in their own tenant; the store is partitioned by
        //    tenant_id so there is nothing cross-tenant to reach.
        Route::get('/requests/{requestId}', [RequestStatusController::class, 'show']);

        // 4. sync: workforce read (Cloud SQL + Memorystore). Salary and commission
        //    are gated separately inside the controller.
        Route::get('/employees', [EmployeeController::class, 'index'])
            ->middleware('can:'.Ability::EMPLOYEES_VIEW);

        Route::get('/audit-logs', [AuditController::class, 'index'])
            ->middleware('can:'.Ability::AUDIT_VIEW);
    });
});
