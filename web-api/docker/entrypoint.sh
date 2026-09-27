#!/bin/sh
#
# Container entrypoint for the Laravel web API.
#
# Caches config/routes at boot rather than baking them into the image, because
# the cached files embed environment values that only exist at runtime (Cloud SQL
# host, Pub/Sub topics, tenant registry).
set -eu

: "${APP_ENV:=production}"

echo "[entrypoint] starting web-api (APP_ENV=${APP_ENV}, pod=$(hostname))"

if [ -z "${APP_KEY:-}" ]; then
    echo "[entrypoint] FATAL: APP_KEY is not set. Mount it from the app secret." >&2
    exit 1
fi

# Warm the caches. A failure here means the config is wrong, so fail fast and let
# the pod crash-loop visibly rather than serve broken responses.
php artisan config:cache
php artisan route:cache

# Views are unused by this API-only service, but caching them keeps `artisan
# about` and any future error page from touching the filesystem at request time.
php artisan view:cache || true

echo "[entrypoint] caches warmed, handing off to: $*"

exec "$@"
