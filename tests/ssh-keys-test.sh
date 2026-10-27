#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/docker/configure-ssh-keys.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

ssh-keygen -q -t ed25519 -N '' -C first -f "$TMP_DIR/first"
ssh-keygen -q -t ed25519 -N '' -C second -f "$TMP_DIR/second"
KEY_ONE="$(cat "$TMP_DIR/first.pub")"
KEY_TWO="$(cat "$TMP_DIR/second.pub")"
AUTHORIZED_KEYS="$TMP_DIR/root/.ssh/authorized_keys"

SSH_PUBLIC_KEYS="${KEY_ONE}\\n${KEY_TWO}" \
AUTHORIZED_KEYS_FILE="$AUTHORIZED_KEYS" \
    "$SCRIPT"

[[ "$(wc -l < "$AUTHORIZED_KEYS")" -eq 2 ]] || fail "expected two authorized keys"
grep -Fxq "$KEY_ONE" "$AUTHORIZED_KEYS" || fail "first key missing"
grep -Fxq "$KEY_TWO" "$AUTHORIZED_KEYS" || fail "second key missing"
[[ "$(mode_of "$(dirname "$AUTHORIZED_KEYS")")" == 700 ]] || fail "SSH directory mode is not 700"
[[ "$(mode_of "$AUTHORIZED_KEYS")" == 600 ]] || fail "authorized_keys mode is not 600"

if SSH_PUBLIC_KEYS='not-a-public-key' AUTHORIZED_KEYS_FILE="$TMP_DIR/invalid/authorized_keys" "$SCRIPT"; then
    fail "invalid key was accepted"
fi

if SSH_PUBLIC_KEYS="bogus-option ${KEY_ONE}" AUTHORIZED_KEYS_FILE="$TMP_DIR/options/authorized_keys" "$SCRIPT"; then
    fail "authorized_keys options were accepted"
fi

if SSH_PUBLIC_KEYS='' AUTHORIZED_KEYS_FILE="$TMP_DIR/empty/authorized_keys" "$SCRIPT"; then
    fail "empty key list was accepted"
fi

echo "SSH key configuration tests passed"
