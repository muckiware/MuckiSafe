#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -Fq -- "$pattern" "$file" || fail "$file does not contain: $pattern"
}

assert_contains docker/Dockerfile 'openssh-server'
assert_contains docker/Dockerfile 'usermod --password'
assert_contains docker/Dockerfile 'COPY docker/sshd_config /etc/ssh/sshd_config'
assert_contains docker/Dockerfile 'COPY docker/configure-ssh-keys.sh /usr/local/bin/configure-ssh-keys.sh'
assert_contains docker/Dockerfile 'EXPOSE 80 22'

assert_contains docker/entrypoint.sh 'if [ -n "${SSH_PUBLIC_KEYS:-}" ]; then'
assert_contains docker/entrypoint.sh '/usr/local/bin/configure-ssh-keys.sh'
assert_contains docker/entrypoint.sh 'ssh-keygen -q -t ed25519'
assert_contains docker/entrypoint.sh 'ssh-keygen -q -t rsa -b 3072'
assert_contains docker/entrypoint.sh '/usr/sbin/sshd -t'
assert_contains docker/entrypoint.sh '/usr/sbin/sshd'

assert_contains docker/sshd_config 'PermitRootLogin prohibit-password'
assert_contains docker/sshd_config 'PasswordAuthentication no'
assert_contains docker/sshd_config 'KbdInteractiveAuthentication no'
assert_contains docker/sshd_config 'AuthenticationMethods publickey'
assert_contains docker/sshd_config 'AllowUsers root'

if grep -Fq -- '- "${SSH_PORT:-2222}:22"' docker-compose.yml; then
    fail "base Compose file publishes SSH even when SSH is disabled"
fi
assert_contains docker-compose.ssh.yml '- "${SSH_PORT:-2222}:22"'
assert_contains docker-compose.yml 'SSH_PUBLIC_KEYS: ${SSH_PUBLIC_KEYS:-}'
assert_contains .env.example 'SSH_PORT=2222'
assert_contains .env.example 'SSH_PUBLIC_KEYS='

echo "SSH integration wiring tests passed"
