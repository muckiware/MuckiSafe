#!/usr/bin/env bash
set -euo pipefail

# MuckiSafe scheduler entrypoint
# Generates the Supercronic configuration from environment variables so the
# cadence can be changed without rebuilding the image.

MESSENGER_CRON="${MESSENGER_CRON:-*/5 * * * *}"
SCHEDULED_TASK_CRON="${SCHEDULED_TASK_CRON:-*/5 * * * *}"
SCHEDULER_TIMEZONE="${SCHEDULER_TIMEZONE:-UTC}"
CRONTAB_FILE="/tmp/muckisafe.crontab"

log() { echo "[scheduler] $*"; }

# Do not allow an environment value to inject an additional crontab line.
for value in "$MESSENGER_CRON" "$SCHEDULED_TASK_CRON" "$SCHEDULER_TIMEZONE"; do
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        log "ERROR: scheduler configuration must not contain line breaks"
        exit 1
    fi
done

cat > "$CRONTAB_FILE" <<EOF
${MESSENGER_CRON} flock -n /tmp/muckisafe-messenger.lock /usr/local/bin/php /var/www/html/bin/console messenger:consume low_priority failed async --time-limit=60 --memory-limit=512M --no-interaction --env=prod
${SCHEDULED_TASK_CRON} flock -n /tmp/muckisafe-scheduled-task.lock /usr/local/bin/php /var/www/html/bin/console scheduled-task:run --time-limit=120 --memory-limit=512M --no-interaction --env=prod
EOF

log "Timezone: ${SCHEDULER_TIMEZONE}"
log "messenger:consume schedule: ${MESSENGER_CRON}"
log "scheduled-task:run schedule: ${SCHEDULED_TASK_CRON}"
log "Starting Supercronic ..."

export TZ="$SCHEDULER_TIMEZONE"
exec /usr/local/bin/supercronic "$CRONTAB_FILE"
