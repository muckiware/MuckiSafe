#!/usr/bin/env bash
set -euo pipefail

AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-/root/.ssh/authorized_keys}"
SSH_DIR="$(dirname "$AUTHORIZED_KEYS_FILE")"
RAW_KEYS="${SSH_PUBLIC_KEYS:-}"

log() { echo "[ssh] $*"; }

if [[ -z "$RAW_KEYS" ]]; then
    log "ERROR: SSH_PUBLIC_KEYS does not contain a public key."
    exit 1
fi

# Docker Compose .env files can represent multiple lines either literally or
# as \n inside a double-quoted value. Accept both forms.
KEYS="${RAW_KEYS//\\n/$'\n'}"

install -d -m 0700 "$SSH_DIR"
TMP_AUTHORIZED_KEYS="$(mktemp "$SSH_DIR/.authorized_keys.XXXXXX")"
TMP_KEY="$(mktemp "$SSH_DIR/.public_key.XXXXXX")"
cleanup() {
    rm -f "$TMP_AUTHORIZED_KEYS" "$TMP_KEY"
}
trap cleanup EXIT
chmod 0600 "$TMP_AUTHORIZED_KEYS" "$TMP_KEY"

key_count=0
while IFS= read -r key || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    [[ -z "$key" ]] && continue

    # Accept bare public-key records only. authorized_keys options are not part
    # of SSH_PUBLIC_KEYS and could alter the intended access policy.
    key_type="${key%%[[:space:]]*}"
    case "$key_type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            log "ERROR: unsupported key type or authorized_keys option at entry $((key_count + 1))."
            exit 1
            ;;
    esac

    printf '%s\n' "$key" > "$TMP_KEY"
    if ! ssh-keygen -l -f "$TMP_KEY" >/dev/null 2>&1; then
        log "ERROR: invalid public key at entry $((key_count + 1))."
        exit 1
    fi

    printf '%s\n' "$key" >> "$TMP_AUTHORIZED_KEYS"
    key_count=$((key_count + 1))
done <<< "$KEYS"

if [[ "$key_count" -eq 0 ]]; then
    log "ERROR: SSH_PUBLIC_KEYS does not contain a public key."
    exit 1
fi

mv -f "$TMP_AUTHORIZED_KEYS" "$AUTHORIZED_KEYS_FILE"
chmod 0600 "$AUTHORIZED_KEYS_FILE"
trap - EXIT
rm -f "$TMP_KEY"
log "Configured ${key_count} SSH public key(s)."
