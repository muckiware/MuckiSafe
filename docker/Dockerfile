# syntax=docker/dockerfile:1
#
# MuckiSafe image — the muckidrive platform (Shopware 6.7 core framework,
# no shop context) combined with the Muckiware facility and logging plugins
# into a ready-to-run backup server.
#
# Build context = this (MuckiSafe) repository root with the muckidrive
# platform cloned into the ./muckidrive subdirectory. The CI workflow does
# this automatically; locally run:
#   git clone https://github.com/muckiware/muckidrive.git muckidrive
#
# Plugins are added at build time via composer (Packagist) — they do NOT live
# in muckidrive (which is a general platform):
#   - muckiware/facility-plugin      (MuckiFacilityPlugin, version below)
#   - muckiware/facility-menu-plugin (MuckiFacilityMenuPlugin, version below)
#   - muckiware/log-plugin           (MuckiLogPlugin, version below)
# They are installed/activated/updated on every container start by
# shopware/deployment-helper (docker/entrypoint.sh), because that needs a DB.
# The restic PHP client library (muckiware/restic, no Packagist) is cloned —
# the custom/muckiware/* path repo in muckidrive's composer.json picks it up.

# ---------------------------------------------------------------------------
# Stage 1: dependencies + administration build (discarded afterwards)
# ---------------------------------------------------------------------------
FROM php:8.4-fpm-bookworm AS build

ARG MUCKIDRIVE_REF=main
ARG FACILITY_PLUGIN_VERSION=0.8.0
ARG FACILITY_MENU_PLUGIN_VERSION=1.0.0
ARG LOG_PLUGIN_VERSION=2.4.0
ARG DEPLOYMENT_HELPER_VERSION=0.1.11
ARG RESTIC_LIB_REF=v1.5.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip curl jq ca-certificates \
        libzip-dev libicu-dev libpng-dev libjpeg-dev libfreetype6-dev libsodium-dev \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli intl gd zip sodium opcache bcmath

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Node.js 22 for the administration build (Vue 3 + Vite)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html

# Platform skeleton from the muckidrive checkout inside the build context.
# muckidrive does not commit a composer.lock: dependencies are resolved at
# build time, so new muckiware/core and muckiware/master releases end up in
# the image (muckidrive's composer.json bounds their versions).
COPY muckidrive/composer.json muckidrive/symfony.lock ./
COPY muckidrive/bin ./bin
COPY muckidrive/config ./config
COPY muckidrive/files ./files
COPY muckidrive/public ./public
COPY muckidrive/src ./src
COPY muckidrive/.htaccess ./
COPY muckidrive/custom/muckiware ./custom/muckiware

# --- MuckiSafe additions -----------------------------------------------------
# restic PHP client library (no Packagist) from its public GitHub tag.
# Defensive cleanup first: local checkouts inside the cloned muckidrive tree
# (gitignored there) would collide with git clone, and local plugin checkouts
# in custom/plugins would shadow the Packagist packages via the path repo.
RUN rm -rf custom/muckiware/restic \
        custom/plugins/MuckiFacilityPlugin \
        custom/plugins/MuckiFacilityMenuPlugin \
        custom/plugins/MuckiLogPlugin \
 && git clone --depth 1 --branch ${RESTIC_LIB_REF} https://github.com/muckiware/restic.git custom/muckiware/restic \
 && rm -rf custom/muckiware/restic/.git

# Plugins + shopware/deployment-helper from Packagist. custom/apps, custom/plugins and custom/static-plugins
# are referenced by composer.json path repositories — create them so composer
# does not fail on missing dirs.
RUN mkdir -p custom/apps custom/plugins custom/static-plugins \
 && composer require muckiware/facility-plugin:"${FACILITY_PLUGIN_VERSION}" --no-interaction --no-scripts \
 && composer require muckiware/facility-menu-plugin:"${FACILITY_MENU_PLUGIN_VERSION}" --no-interaction --no-scripts \
 && composer require muckiware/log-plugin:"${LOG_PLUGIN_VERSION}" --no-interaction --no-scripts \
 && composer require shopware/deployment-helper:"${DEPLOYMENT_HELPER_VERSION}" --no-interaction --no-scripts \
 && composer dump-autoload --optimize \
 && composer install --no-dev --optimize-autoloader --no-interaction

# muckidrive does not load the Shopware storefront bundle. The MuckiLogPlugin
# storefront ErrorControllerDecorator (shipped in v2.4.0) decorates a service
# that does not exist here and would break container compilation — the service
# block is removed during the build (verified against SW 6.7.15.1).
RUN LOG_SERVICES=vendor/muckiware/log-plugin/src/Resources/config/services.xml \
 && sed -i '/<service id="MuckiLogPlugin\\Storefront\\Controller\\ErrorControllerDecorator"/,/<\/service>/d' "$LOG_SERVICES" \
 && ! grep -q ErrorControllerDecorator "$LOG_SERVICES" \
 && php -r 'exit(simplexml_load_file($argv[1]) === false ? 1 : 0);' "$LOG_SERVICES" \
 && echo "MuckiLogPlugin services.xml patched and valid"

# Administration production build (no database required — verified:
# bundle:dump, feature:dump, framework:schema and assets:install all run
# without a DB connection)
ENV APP_ENV=prod \
    MUCKIWARE_ROOT=/var/www/html \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    DISABLE_ADMIN_COMPILATION_TYPECHECK=true \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false

RUN bash bin/build-administration.sh

# ---------------------------------------------------------------------------
# Stage 2: runtime (Apache + PHP; Node.js 22 + Composer for console tasks)
# ---------------------------------------------------------------------------
FROM php:8.4-apache-bookworm

ARG TARGETARCH
ARG COMPOSER_VERSION=2.7.7
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256_AMD64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_ARM64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94

# Debian locks root by default. Give it a discarded random password hash so
# OpenSSH permits public-key login; sshd_config still disables all password
# and interactive authentication.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates openssl passwd restic netcat-openbsd util-linux tzdata openssh-server \
        git unzip \
        libzip-dev libicu-dev libpng-dev libjpeg-dev libfreetype6-dev libsodium-dev \
    && ROOT_SSH_PASSWORD="$(openssl rand -base64 48)" \
    && ROOT_SSH_HASH="$(printf '%s' "$ROOT_SSH_PASSWORD" | openssl passwd -6 -stdin)" \
    && usermod --password "$ROOT_SSH_HASH" root \
    && unset ROOT_SSH_PASSWORD ROOT_SSH_HASH \
    && case "${TARGETARCH}" in \
        amd64) SUPERCRONIC_SHA256="${SUPERCRONIC_SHA256_AMD64}" ;; \
        arm64) SUPERCRONIC_SHA256="${SUPERCRONIC_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
        -o /usr/local/bin/supercronic \
    && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod +x /usr/local/bin/supercronic \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && a2enmod rewrite headers

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli intl gd zip sodium opcache bcmath

# Node.js 22 and pinned Composer for console/build/debug tasks inside the
# container (SSH sessions, docker compose exec). The running app itself does
# not depend on them. The Composer SHA-384 was cross-verified against both
# getcomposer.org and the composer/composer GitHub release asset.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" \
        -o /usr/local/bin/composer \
    && echo "a63342c65fa12bab2c079f4ea64d621aaeabbbb42942aeb113a78044c2325781bf887f64fd479e0c38dd4f7a720067d4  /usr/local/bin/composer" | sha384sum -c - \
    && chmod +x /usr/local/bin/composer \
    && node --version \
    && npm --version \
    && COMPOSER_HOME=/tmp/composer composer --version

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/scheduler-entrypoint.sh /usr/local/bin/scheduler-entrypoint.sh
COPY docker/configure-ssh-keys.sh /usr/local/bin/configure-ssh-keys.sh
COPY docker/sshd_config /etc/ssh/sshd_config

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/scheduler-entrypoint.sh /usr/local/bin/configure-ssh-keys.sh \
    && sed -i 's|/var/www/html|/var/www/html/public|' /etc/apache2/sites-available/000-default.conf \
    && printf '<Directory /var/www/html/public>\n    AllowOverride All\n    Require all granted\n</Directory>\n' \
       > /etc/apache2/conf-available/docroot.conf \
    && a2enconf docroot \
    && mkdir -p /var/www/html/var \
    && chown -R www-data:www-data /var/www/html

EXPOSE 80 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]