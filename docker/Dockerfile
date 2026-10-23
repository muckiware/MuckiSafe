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
# Plugins are added at build time — they do NOT live in muckidrive (which is
# a general platform):
#   - MuckiFacilityPlugin (github.com/muckiware/MuckiFacilityPlugin, tag below)
#   - MuckiLogPlugin     (github.com/muckiware/MuckiLogPlugin, tag below)
# The restic PHP client library (muckiware/restic, no Packagist) is cloned as
# well — the custom/muckiware/* path repo in muckidrive's composer.json
# picks it up.

# ---------------------------------------------------------------------------
# Stage 1: dependencies + administration build (discarded afterwards)
# ---------------------------------------------------------------------------
FROM php:8.4-fpm-bookworm AS build

ARG MUCKIDRIVE_REF=main
ARG FACILITY_PLUGIN_REF=v0.7.0
ARG LOG_PLUGIN_REF=v2.4.0
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

# Platform skeleton from the muckidrive checkout inside the build context
COPY muckidrive/composer.json muckidrive/composer.lock muckidrive/symfony.lock ./
COPY muckidrive/bin ./bin
COPY muckidrive/config ./config
COPY muckidrive/files ./files
COPY muckidrive/public ./public
COPY muckidrive/src ./src
COPY muckidrive/.htaccess ./
COPY muckidrive/custom/muckiware ./custom/muckiware

# --- MuckiSafe additions: plugins cloned from their public GitHub tags -----
# Defensive cleanup first: local plugin checkouts inside the cloned
# muckidrive tree (gitignored there) would collide with git clone.
RUN rm -rf custom/muckiware/restic custom/plugins/MuckiFacilityPlugin custom/plugins/MuckiLogPlugin \
 && git clone --depth 1 --branch ${FACILITY_PLUGIN_REF} https://github.com/muckiware/MuckiFacilityPlugin.git custom/plugins/MuckiFacilityPlugin \
 && git clone --depth 1 --branch ${LOG_PLUGIN_REF} https://github.com/muckiware/MuckiLogPlugin.git custom/plugins/MuckiLogPlugin \
 && git clone --depth 1 --branch ${RESTIC_LIB_REF} https://github.com/muckiware/restic.git custom/muckiware/restic \
 && rm -rf custom/plugins/MuckiFacilityPlugin/.git custom/plugins/MuckiLogPlugin/.git custom/muckiware/restic/.git

# muckidrive does not load the Shopware storefront bundle. The MuckiLogPlugin
# storefront ErrorControllerDecorator (shipped in v2.4.0) decorates a service
# that does not exist here and would break container compilation — the service
# block is removed during the build (verified against SW 6.7.15.1).
RUN sed -i '/<service id="MuckiLogPlugin\\Storefront\\Controller\\ErrorControllerDecorator"/,/<\/service>/d' \
        custom/plugins/MuckiLogPlugin/src/Resources/config/services.xml \
 && ! grep -q ErrorControllerDecorator custom/plugins/MuckiLogPlugin/src/Resources/config/services.xml \
 && php -r 'exit(simplexml_load_file("custom/plugins/MuckiLogPlugin/src/Resources/config/services.xml") === false ? 1 : 0);' \
 && echo "MuckiLogPlugin services.xml patched and valid"

# Register both plugins with composer (path repos custom/plugins/*, same as DDEV)
# custom/apps and custom/static-plugins are referenced by composer.json path
# repositories — create them so composer does not fail on missing dirs.
RUN mkdir -p custom/apps custom/static-plugins \
 && composer require \
        muckiware/facility-plugin:"*" \
        muckiware/log-plugin:"*" \
        --no-interaction --no-scripts \
 && composer dump-autoload --optimize \
 && composer install --no-dev --optimize-autoloader --no-interaction

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
# Stage 2: runtime (Apache + PHP, no Node.js, no build toolchain)
# ---------------------------------------------------------------------------
FROM php:8.4-apache-bookworm

ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256_AMD64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_ARM64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates restic netcat-openbsd util-linux tzdata \
        libzip-dev libicu-dev libpng-dev libjpeg-dev libfreetype6-dev libsodium-dev \
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
    && a2enmod rewrite headers

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli intl gd zip sodium opcache bcmath

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/scheduler-entrypoint.sh /usr/local/bin/scheduler-entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/scheduler-entrypoint.sh \
    && sed -i 's|/var/www/html|/var/www/html/public|' /etc/apache2/sites-available/000-default.conf \
    && printf '<Directory /var/www/html/public>\n    AllowOverride All\n    Require all granted\n</Directory>\n' \
       > /etc/apache2/conf-available/docroot.conf \
    && a2enconf docroot \
    && mkdir -p /var/www/html/var \
    && chown -R www-data:www-data /var/www/html

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]