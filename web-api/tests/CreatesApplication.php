<?php

namespace Tests;

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Config;

trait CreatesApplication
{
    /**
     * Creates the application.
     *
     * @return \Illuminate\Foundation\Application
     */
    public function createApplication()
    {
        $app = require __DIR__.'/../bootstrap/app.php';

        $app->make(Kernel::class)->bootstrap();

        $this->forceTestConfiguration();

        return $app;
    }

    /**
     * Pin the test configuration in code rather than trusting the environment.
     *
     * PHPUnit's <env force="true"> sets $_ENV and putenv, but not $_SERVER - and on
     * the CLI SAPI $_SERVER often carries the shell's exported variables. Laravel's
     * env() consults $_SERVER first, so a developer who has sourced a local dev
     * profile silently gets different test configuration from everyone else.
     *
     * That is not a theoretical problem: it produced a failure here where an
     * inherited SANCTUM_STATEFUL_DOMAINS stopped Sanctum treating test requests as
     * first-party, and every authenticated test failed with "Session store not set
     * on request" - an error that points nowhere near the real cause.
     *
     * Setting config directly is unambiguous and cannot be overridden by a shell.
     */
    private function forceTestConfiguration(): void
    {
        Config::set([
            'cache.default' => 'array',

            /*
             * The file driver, not array.
             *
             * The array driver keeps the session only in the Store object, which
             * Laravel reuses across requests inside one test. A session cookie
             * therefore appears to "work" without ever being read, and a test that
             * means to exercise cookie-based auth would pass for the wrong reason.
             * The file driver makes the cookie the only thing carrying the session,
             * as it is in production.
             */
            'session.driver' => 'file',

            'queue.default' => 'sync',
            'mail.default' => 'array',
            'logging.default' => 'null',

            // No GCP. The log publisher captures envelopes; the cache-backed status
            // store keeps request statuses in memory.
            'gcp.pubsub.driver' => 'log',
            'gcp.pubsub.emulator_host' => null,
            'gcp.firestore.driver' => 'cache',
            'gcp.firestore.emulator_host' => null,
            'gcp.project_id' => 'test-project',

            // Tenants are addressed by hostname, exactly as in production. The
            // header shortcut stays off so TenancyIsolationTest genuinely proves it
            // cannot be used to cross tenants.
            'tenancy.base_domains' => ['sequifi.com'],
            'tenancy.trust_header' => false,
            'tenancy.template_connection' => 'sqlite',

            // Tenant subdomains must be first-party or no session is ever started.
            'sanctum.stateful' => ['*.sequifi.com'],
            'session.domain' => null,
            'session.secure' => false,

            // Rate limits high enough not to interfere with a fast test suite.
            'app.rate_limit_per_tenant' => 10000,
            'app.rate_limit_per_client' => 10000,

            // Cheap hashing: BCRYPT_ROUNDS=4 is the difference between a suite that
            // runs in seconds and one that runs in minutes.
            'hashing.bcrypt.rounds' => 4,
        ]);
    }
}
