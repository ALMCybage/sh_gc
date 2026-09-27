<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Tenant Resolution
    |--------------------------------------------------------------------------
    |
    | Requests arrive at the GKE Ingress as https://<tenant>.sequifi.com. The
    | ResolveTenant middleware resolves the tenant from (in order):
    |
    |   1. the "X-Tenant" header  (handy for curl / smoke tests)
    |   2. the request Host header (the production path)
    |
    | Everything after resolution is tenant-scoped: the MySQL schema, the Redis
    | cache/session prefix, the Firestore partition key and the Pub/Sub message
    | attributes handed to the Go worker.
    |
    */

    'header' => env('TENANCY_HEADER', 'X-Tenant'),

    /*
    |--------------------------------------------------------------------------
    | Trusting the tenant header
    |--------------------------------------------------------------------------
    |
    | OFF by default, and it must stay off in production.
    |
    | The header is a client-supplied value. If it is honoured ahead of the Host
    | header, anyone can point a request at another tenant's schema by adding
    | "X-Tenant: victim" to a call aimed at their own hostname. Session binding
    | (EnsureSessionTenant) stops that becoming a cross-tenant read, but relying
    | on a second control to save you from a first one you chose to leave open is
    | not a security posture.
    |
    | Enable it only for local development and smoke tests, where addressing
    | tenants by header is genuinely more convenient than by subdomain.
    |
    */
    'trust_header' => (bool) env('TENANCY_TRUST_HEADER', false),

    /*
    | Comma-separated list of base domains. The left-most label of a matching
    | host is the tenant id, so "acme.sequifi.com" and "acme.localhost:5173"
    | both resolve to "acme". Listing localhost lets the dev SPA use real
    | per-tenant hostnames instead of a header, which in turn keeps browser
    | cookies scoped per tenant exactly as they are in production.
    */
    'base_domains' => array_values(array_filter(array_map(
        'trim',
        explode(',', (string) env('TENANCY_BASE_DOMAINS', env('TENANCY_BASE_DOMAIN', 'sequifi.com').',localhost'))
    ))),

    /*
    | Connection used as the template for every tenant connection. At runtime
    | TenantManager clones it and swaps only the "database" (schema) name, which
    | is what "Shared Application - Multi-Database" in the architecture means.
    */
    'template_connection' => env('TENANCY_TEMPLATE_CONNECTION', 'mysql'),

    /*
    | Name of the dynamically-configured connection. Models that extend
    | App\Models\TenantModel bind to this connection.
    */
    'runtime_connection' => 'tenant',

    'schema_prefix' => env('TENANCY_SCHEMA_PREFIX', 'tenant_'),

    /*
    |--------------------------------------------------------------------------
    | Tenant Registry
    |--------------------------------------------------------------------------
    |
    | In a real deployment this would live in a central "landlord" database or
    | in Firestore. For this sample it is a static registry so the app boots
    | with zero external dependencies. Override with TENANTS_JSON, e.g.
    |
    |   TENANTS_JSON='{"acme":{"name":"Acme","database":"tenant_acme"}}'
    |
    */

    'tenants' => env('TENANTS_JSON')
        ? json_decode(env('TENANTS_JSON'), true)
        : [
            'acme' => [
                'name' => 'Acme Corp',
                'database' => 'tenant_acme',
                'domain' => 'acme.sequifi.com',
                'payroll_currency' => 'USD',
            ],
            'whiteknight' => [
                'name' => 'White Knight',
                'database' => 'tenant_whiteknight',
                'domain' => 'whiteknight.sequifi.com',
                'payroll_currency' => 'USD',
            ],
            'frdm' => [
                'name' => 'FRDM',
                'database' => 'tenant_frdm',
                'domain' => 'frdm.sequifi.com',
                'payroll_currency' => 'USD',
            ],
        ],

    /*
    | Tenant used when the Host header carries no recognisable subdomain
    | (localhost, kube-probe, the load balancer health check, ...).
    */
    'fallback' => env('TENANCY_FALLBACK_TENANT', 'acme'),

];
