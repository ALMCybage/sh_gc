<?php

namespace Tests\Unit;

use Illuminate\Http\Request;
use Laravel\Sanctum\Http\Middleware\EnsureFrontendRequestsAreStateful;
use Tests\TestCase;

/**
 * Sanctum only starts a session when the request's Origin/Referer matches
 * sanctum.stateful. If that list is wrong, every authenticated request fails for a
 * reason that has nothing to do with the credentials, so it is worth asserting
 * directly rather than debugging it through a controller.
 */
class SanctumStatefulTest extends TestCase
{
    public function test_tenant_subdomains_are_treated_as_first_party(): void
    {
        $this->assertNotEmpty(config('sanctum.stateful'), 'sanctum.stateful is empty');

        $request = Request::create('http://acme.sequifi.com/api/v1/auth/user');
        $request->headers->set('Referer', 'http://acme.sequifi.com/');

        $this->assertTrue(
            EnsureFrontendRequestsAreStateful::fromFrontend($request),
            'A tenant subdomain must be stateful. Configured: '.json_encode(config('sanctum.stateful'))
        );
    }

    public function test_third_party_origin_is_not_stateful(): void
    {
        $request = Request::create('http://acme.sequifi.com/api/v1/auth/user');
        $request->headers->set('Referer', 'https://evil.example.com/');

        $this->assertFalse(EnsureFrontendRequestsAreStateful::fromFrontend($request));
    }
}
