#!/usr/bin/env bash
set -e

# MuckiSafe container entrypoint
# Waits for the database, installs the system on first boot,
# installs/updates all plugins via shopware/deployment-helper, then starts Apache.

WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"

log() { echo "[entrypoint] $*"; }

# --------------------------------------------------------------- start SSH
# SSH is opt-in: without at least one public key, no SSH daemon is started.
# Password and interactive authentication are disabled in sshd_config.
if [ -n "${SSH_PUBLIC_KEYS:-}" ]; then
    /usr/local/bin/configure-ssh-keys.sh
    mkdir -p /run/sshd /var/lib/muckisafe-ssh
    if [ ! -f /var/lib/muckisafe-ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -q -t ed25519 -N '' -f /var/lib/muckisafe-ssh/ssh_host_ed25519_key
    fi
    if [ ! -f /var/lib/muckisafe-ssh/ssh_host_rsa_key ]; then
        ssh-keygen -q -t rsa -b 3072 -N '' -f /var/lib/muckisafe-ssh/ssh_host_rsa_key
    fi
    /usr/sbin/sshd -t
    /usr/sbin/sshd
    log "SSH server started (root login with public key only)."
else
    log "SSH disabled: SSH_PUBLIC_KEYS is empty."
fi

# ---------------------------------------------------------------- wait for DB
if [ -n "$DATABASE_URL" ]; then
    log "Waiting up to ${WAIT_TIMEOUT}s for database ..."
    # extract host and port from DATABASE_URL
    DB_HOST="$(echo "$DATABASE_URL" | sed -E 's|.*@([^:/]+).*|\1|')"
    DB_PORT="$(echo "$DATABASE_URL" | sed -nE 's|.*:([0-9]+).*|\1|p')"
    DB_PORT="${DB_PORT:-3306}"

    elapsed=0
    until nc -z "$DB_HOST" "$DB_PORT" 2>/dev/null; do
        if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
            log "ERROR: database not reachable after ${WAIT_TIMEOUT}s"
            exit 1
        fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    log "Database is reachable."
else
    log "WARNING: DATABASE_URL is not set - skipping install checks."
fi

# ------------------------------------------------------- image fingerprint
# The image stores a fingerprint of its composer.lock; the var volume keeps the
# fingerprint of the image that was applied to this database last. A mismatch
# means "new image": the compiled container in var/cache belongs to the old
# code and the migrations of the new code have not run yet.
export MUCKIWARE_ROOT="${MUCKIWARE_ROOT:-/var/www/html}"

IMAGE_FINGERPRINT="$(cat .image-fingerprint 2>/dev/null || echo unknown)"
APPLIED_FINGERPRINT_FILE=var/.muckisafe-image-fingerprint
APPLIED_FINGERPRINT="$(cat "$APPLIED_FINGERPRINT_FILE" 2>/dev/null || true)"

NEW_IMAGE=0
if [ "$IMAGE_FINGERPRINT" != "$APPLIED_FINGERPRINT" ]; then
    NEW_IMAGE=1
    log "New image detected (${APPLIED_FINGERPRINT:-none} -> ${IMAGE_FINGERPRINT})."
    # Mark the update as running. A scheduler container of the previous image
    # sees a fingerprint that is not its own and stops running jobs, so it can
    # no longer write a cache built from the old code into the shared volume.
    echo "pending:${IMAGE_FINGERPRINT}" > "$APPLIED_FINGERPRINT_FILE"
    log "Dropping the cache of the previous image ..."
    mkdir -p var/cache
    find var/cache -mindepth 1 -delete
fi

# ------------------------------------------------------------- first install
# Decide "fresh database" by looking at the database itself, not by booting
# the application: a console command that fails for any other reason (broken
# cache, PHP error) must never lead to system:install on existing data.
if ! TABLE_COUNT="$(php /usr/local/bin/db-probe.php tables)"; then
    log "ERROR: cannot inspect the database - refusing to continue."
    exit 1
fi

FRESH_INSTALL=0
if [ "$TABLE_COUNT" -eq 0 ]; then
    # The deployment helper below needs at least one user to recognise the
    # installation, so the admin user is mandatory on first boot.
    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        log "ERROR: first installation requires ADMIN_USERNAME and ADMIN_PASSWORD."
        exit 1
    fi

    log "Database is empty - running system:install ..."
    bin/console system:install -n \
        --create-database \
        --shop-name "${PROJECT_NAME:-MuckiSafe}" \
        --shop-email "${PROJECT_EMAIL:-admin@example.com}" \
        --shop-locale "${PROJECT_LOCALE:-en-GB}" \
        --skip-assets-install \
        --skip-first-run-wizard \
        --no-assign-theme

    FRESH_INSTALL=1
    log "System installation finished."
elif ! INSTALL_CHECK="$(bin/console system:is-installed 2>&1)"; then
    log "ERROR: the database contains ${TABLE_COUNT} tables, but system:is-installed failed:"
    echo "$INSTALL_CHECK"
    log "       Refusing to reinstall over existing data. If the very first"
    log "       installation was interrupted, start again with an empty database."
    exit 1
fi

# Create the admin user whenever there is none - also on a later boot, so an
# installation whose user creation failed heals itself once the values are set.
if ! USER_COUNT="$(php /usr/local/bin/db-probe.php users)"; then
    log "ERROR: cannot inspect the database - refusing to continue."
    exit 1
fi

if [ "$USER_COUNT" -eq 0 ]; then
    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        log "ERROR: there is no user yet - set ADMIN_USERNAME and ADMIN_PASSWORD."
        exit 1
    fi

    log "Creating admin user '${ADMIN_USERNAME}' ..."
    bin/console -n user:create \
        --admin \
        --password "$ADMIN_PASSWORD" \
        --email "${ADMIN_EMAIL:-admin@example.com}" \
        --firstName "${ADMIN_FIRSTNAME:-Admin}" \
        --lastName "${ADMIN_LASTNAME:-User}" \
        "$ADMIN_USERNAME"
fi

# ------------------------------------------- plugins + updates (every boot)
# shopware/deployment-helper on an installed system: runs migrations when the
# shopware/core version changed, plugin:refresh, installs new plugins
# (custom/plugins + composer-installed), updates outdated ones, activates
# inactive ones and runs scheduled-task:register.
#
# The helper only considers a DB installed if it has at least one row in
# `user` AND in `sales_channel`. Otherwise it would run its own fresh install
# ("system:install --force") on the existing database — refuse instead.
DEPLOYMENT_HELPER=vendor/bin/shopware-deployment-helper

if ! "$DEPLOYMENT_HELPER" is-installed >/dev/null 2>&1; then
    log "ERROR: the deployment helper does not recognise this installation."
    log "       It needs at least one row in the 'user' and 'sales_channel' tables."
    exit 1
fi

# The helper runs system:update:finish only when the shopware/core version
# changed. muckiware/core and muckiware/master ship migrations as well and can
# be released without a shopware/core bump, so run it for every new image.
if [ "$NEW_IMAGE" -eq 1 ] && [ "$FRESH_INSTALL" -eq 0 ]; then
    log "Running migrations of the new image (system:update:finish) ..."
    bin/console -n system:update:finish --skip-asset-build
fi

# No storefront in muckidrive: skip theme compilation. Assets are built and
# installed at image build time (bin/build-administration.sh with CI=1).
log "Running shopware-deployment-helper ..."
"$DEPLOYMENT_HELPER" run --skip-theme-compile --skip-assets-install
bin/console -n cache:clear

# Everything above succeeded: this image is now the applied one.
echo "$IMAGE_FINGERPRINT" > "$APPLIED_FINGERPRINT_FILE"

# Files created above are owned by root (entrypoint user); the web server
# runs as www-data and needs write access to var/ (cache, logs), public/ and
# files/ (private filesystem).
chown -R www-data:www-data var public files

# ------------------------------------------------------------- start Apache
log "Starting Apache ..."
exec "$@"