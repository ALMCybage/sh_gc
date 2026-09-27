# syntax=docker/dockerfile:1
#
# Stateless Core Web API - PHP 8.2 / Laravel 9 on php-fpm.
# Runs as a sidecar pair with nginx (see deploy/k8s/10-web-api.yaml).

########################################################################
# Stage 1: composer dependencies
########################################################################
FROM composer:2.8 AS vendor

WORKDIR /app

# Only the manifests, so this layer is reused across application code changes.
COPY composer.json composer.lock ./

# --no-scripts because artisan is not here yet. The autoloader is regenerated in
# the runtime stage once the application code is present, otherwise the optimized
# classmap would be built without any App\ classes in it.
RUN composer install \
        --no-dev \
        --no-interaction \
        --no-progress \
        --no-scripts \
        --no-autoloader \
        --prefer-dist

########################################################################
# Stage 2: runtime
########################################################################
FROM php:8.2-fpm-alpine AS runtime

# pdo_mysql for Cloud SQL, opcache for throughput. No grpc/protobuf: this service
# reaches Pub/Sub and Firestore over REST, which keeps the image small.
RUN set -eux; \
    apk add --no-cache --virtual .build-deps $PHPIZE_DEPS; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql opcache; \
    apk del .build-deps; \
    rm -rf /tmp/* /var/cache/apk/*

# Composer is needed only to dump the autoloader; it is removed below so the
# runtime image ships no package manager.
COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

COPY --from=vendor /app/vendor ./vendor
COPY . .

COPY docker/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php-fpm.conf /usr/local/etc/php-fpm.d/zz-app.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh; \
    rm -rf docker tests phpunit.xml webpack.mix.js package.json; \
    # Explicit paths: busybox sh has no brace expansion.
    mkdir -p storage/framework/cache storage/framework/sessions \
             storage/framework/views storage/logs bootstrap/cache; \
    composer dump-autoload --no-dev --optimize --no-interaction; \
    php artisan package:discover --ansi; \
    rm -f /usr/bin/composer; \
    # www-data owns only what has to be writable. Application code stays
    # read-only to the runtime user, so a compromised request cannot rewrite it.
    chown -R www-data:www-data storage bootstrap/cache; \
    chmod -R 0775 storage bootstrap/cache

# Non-root, as required by GKE Autopilot's default security posture.
USER www-data

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]
