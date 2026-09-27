<?php

return [

    'project_id' => env('GOOGLE_CLOUD_PROJECT', 'local-dev'),

    /*
    |--------------------------------------------------------------------------
    | Pub/Sub
    |--------------------------------------------------------------------------
    |
    | Drivers:
    |   rest  - talks to the Pub/Sub v1 REST API. Uses PUBSUB_EMULATOR_HOST when
    |           set (no credentials needed), otherwise Application Default
    |           Credentials, which on GKE means Workload Identity.
    |   log   - writes the envelope to the Laravel log instead of publishing.
    |           Lets you exercise the HTTP layer with no GCP and no emulator.
    |
    */

    'pubsub' => [
        'driver' => env('PUBSUB_DRIVER', 'rest'),

        'emulator_host' => env('PUBSUB_EMULATOR_HOST'),

        'timeout' => (float) env('PUBSUB_TIMEOUT', 3.0),

        'topics' => [
            'payroll' => env('PUBSUB_TOPIC_PAYROLL', 'payroll-calc-events'),
            'sales' => env('PUBSUB_TOPIC_SALES', 'sales-import'),
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Firestore (API request statuses / health tracking)
    |--------------------------------------------------------------------------
    |
    | Accessed over the Firestore REST API so the container does not need the
    | gRPC PHP extension. Documents are partitioned by tenant_id, replacing the
    | per-pod SQLite file the legacy stack used.
    |
    | Drivers: rest | redis (fallback for offline dev) | null
    |
    */

    'firestore' => [
        'driver' => env('FIRESTORE_DRIVER', 'rest'),

        'database' => env('FIRESTORE_DATABASE', '(default)'),

        'collection' => env('FIRESTORE_COLLECTION', 'api_request_statuses'),

        'emulator_host' => env('FIRESTORE_EMULATOR_HOST'),

        'timeout' => (float) env('FIRESTORE_TIMEOUT', 3.0),
    ],

    /*
    | Scope requested when minting an access token from ADC.
    */
    'auth_scopes' => [
        'https://www.googleapis.com/auth/cloud-platform',
    ],

];
