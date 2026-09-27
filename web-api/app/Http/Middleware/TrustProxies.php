<?php

namespace App\Http\Middleware;

use Illuminate\Http\Middleware\TrustProxies as Middleware;
use Illuminate\Http\Request;

class TrustProxies extends Middleware
{
    /**
     * Inside GKE the only thing that can reach a pod on the container port is
     * the Google load balancer (via the NEG) or another pod in the cluster, so
     * trusting the forwarded headers is correct here. Without this, tenant
     * resolution from the Host header and the rate-limiter's client IP would
     * both see the load balancer instead of the caller.
     *
     * @var array<int, string>|string|null
     */
    protected $proxies = '*';

    /**
     * @var int
     */
    protected $headers =
        Request::HEADER_X_FORWARDED_FOR |
        Request::HEADER_X_FORWARDED_HOST |
        Request::HEADER_X_FORWARDED_PORT |
        Request::HEADER_X_FORWARDED_PROTO;
}
