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

# ------------------------------------------------------------- first install
export MUCKIWARE_ROOT="${MUCKIWARE_ROOT:-/var/www/html}"

if ! bin/console system:is-installed >/dev/null 2>&1; then
    # The deployment helper below needs at least one user to recognise the
    # installation, so the admin user is mandatory on first boot.
    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        log "ERROR: first installation requires ADMIN_USERNAME and ADMIN_PASSWORD."
        exit 1
    fi

    log "System not installed - running system:install ..."
    bin/console system:install -n \
        --create-database \
        --shop-name "${PROJECT_NAME:-MuckiSafe}" \
        --shop-email "${PROJECT_EMAIL:-admin@example.com}" \
        --shop-locale "${PROJECT_LOCALE:-en-GB}" \
        --skip-assets-install \
        --skip-first-run-wizard \
        --no-assign-theme

    log "Creating admin user '${ADMIN_USERNAME}' ..."
    bin/console -n user:create \
        --admin \
        --password "$ADMIN_PASSWORD" \
        --email "${ADMIN_EMAIL:-admin@example.com}" \
        --firstName "${ADMIN_FIRSTNAME:-Admin}" \
        --lastName "${ADMIN_LASTNAME:-User}" \
        "$ADMIN_USERNAME"

    log "First installation finished."
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
    log "       Create an admin user with 'bin/console user:create --admin' and restart."
    exit 1
fi

# No storefront in muckidrive: skip theme compilation. Assets are installed at
# image build time (bin/build-administration.sh).
log "Running shopware-deployment-helper ..."
"$DEPLOYMENT_HELPER" run --skip-theme-compile --skip-assets-install
bin/console -n cache:clear

# Files created above are owned by root (entrypoint user); the web server
# runs as www-data and needs write access to var/ (cache, logs).
chown -R www-data:www-data var public

# ------------------------------------------------------------- start Apache
log "Starting Apache ..."
exec "$@"