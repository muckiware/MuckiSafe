FROM php:8.4-fpm-bookworm AS build

# System dependencies for Composer + Node build
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip curl ca-certificates \
        libzip-dev libicu-dev libpng-dev libjpeg-dev libfreetype6-dev libsodium-dev \
    && rm -rf /var/lib/apt/lists/*

# PHP extensions required by Shopware 6.7 core + Muckiware plugins
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli intl gd zip sodium opcache bcmath

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Node.js 22 LTS for the administration build
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html

# Dependencies first (better layer caching)
COPY composer.json composer.lock symfony.lock ./
COPY config ./config
COPY src ./src
COPY custom/muckiware ./custom/muckiware

# Fetch the Muckiware plugins from GitHub (public repos, tagged releases)
RUN git clone --depth 1 --branch v0.7.0 https://github.com/muckiware/MuckiFacilityPlugin.git custom/plugins/MuckiFacilityPlugin \
 && git clone --depth 1 --branch v2.4.0 https://github.com/muckiware/MuckiLogPlugin.git custom/plugins/MuckiLogPlugin \
 && rm -rf custom/plugins/MuckiFacilityPlugin/.git custom/plugins/MuckiLogPlugin/.git \
 && rm -rf custom/plugins/MuckiLogPlugin/src/Resources/config/services.xml

# Platform requirements from the plugins (restic PHP library etc.)
RUN git clone --depth 1 --branch v1.5.0 https://github.com/muckiware/restic.git custom/muckiware/restic \
 && rm -rf custom/muckiware/restic/.git

RUN composer install --no-dev --optimize-autoloader --no-interaction

# Administration build (Vue 3 + Vite, inside custom/muckiware/master)
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    DISABLE_ADMIN_COMPILATION_TYPECHECK=true \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false
RUN bin/build-administration.sh

# ---------------------------------------------------------------------------
FROM php:8.4-apache-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        libzip4 libicu72 libpng16-16 libjpeg62-turbo libfreetype6 libsodium23 \
        curl ca-certificates restic \
    && rm -rf /var/lib/apt/lists/* \
    && a2enmod rewrite headers \
    && echo "ServerName localhost" >> /etc/apache2/apache2.conf

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli intl gd zip sodium opcache bcmath

WORKDIR /var/www/html

COPY --from=build /var/www/html /var/www/html
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chown -R www-data:www-data /var/www/html \
    && sed -i 's|/var/www/html|/var/www/html/public|' /etc/apache2/sites-available/000-default.conf \
    && printf '<Directory /var/www/html/public>\n    AllowOverride All\n    Require all granted\n</Directory>\n' > /etc/apache2/conf-available/docroot.conf \
    && a2enconf docroot

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]