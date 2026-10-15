# syntax=docker/dockerfile:1
#
# MuckiSafe image — muckidrive (Shopware 6.7 core framework, no shop context)
# with MuckiFacilityPlugin and MuckiLogPlugin pre-installed.
#
# Build context = muckidrive repository root (needs: composer.json/composer.lock,
# bin/, config/, files/, public/, src/, .htaccess, custom/muckiware/).
# Plugins and the restic PHP library are cloned from their public GitHub repos.

# ---------------------------------------------------------------------------
# Stage 1: dependencies + administration build (discarded afterwards)
# ---------------------------------------------------------------------------
FROM php:8.4-fpm-bookworm AS build

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

# Application skeleton (ordered for layer caching)
COPY composer.json composer.lock symfony.lock ./
COPY bin ./bin
COPY config ./config
COPY files ./files
COPY public ./public
COPY src ./src
COPY .htaccess ./
COPY custom/muckiware ./custom/muckiware

# muckidrive ships custom/muckiware/restic (PHP restic client, path repo).
# Plugins are cloned from their public GitHub tags.
RUN git clone --depth 1 --branch v0.7.0 https://github.com/muckiware/MuckiFacilityPlugin.git custom/plugins/MuckiFacilityPlugin \
 && git clone --depth 1 --branch v2.4.0 https://github.com/muckiware/MuckiLogPlugin.git custom/plugins/MuckiLogPlugin \
 && rm -rf custom/plugins/MuckiFacilityPlugin/.git custom/plugins/MuckiLogPlugin/.git

# muckidrive does not load the Shopware storefront bundle. The MuckiLogPlugin
# storefront ErrorControllerDecorator (shipped in v2.4.0) decorates a service
# that does not exist here and would break container compilation — the service
# block is removed (tested against SW 6.7.15.1).
RUN sed -i '/<service id="MuckiLogPlugin\\Storefront\\Controller\\ErrorControllerDecorator"/,/<\/service>/d' \
        custom/plugins/MuckiLogPlugin/src/Resources/config/services.xml \
 && ! grep -q ErrorControllerDecorator custom/plugins/MuckiLogPlugin/src/Resources/config/services.xml

RUN composer install --no-dev --optimize-autoloader --no-interaction

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

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates restic netcat-openbsd \
        libzip-dev libicu-dev libpng-dev libjpeg-dev libfreetype6-dev libsodium-dev \
    && rm -rf /var/lib/apt/lists/* \
    && a2enmod rewrite headers

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli intl gd zip sodium opcache bcmath

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && sed -i 's|/var/www/html|/var/www/html/public|' /etc/apache2/sites-available/000-default.conf \
    && printf '<Directory /var/www/html/public>\n    AllowOverride All\n    Require all granted\n</Directory>\n' \
       > /etc/apache2/conf-available/docroot.conf \
    && a2enconf docroot \
    && mkdir -p /var/www/html/var \
    && chown -R www-data:www-data /var/www/html

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]