#!/usr/bin/env bash
# shellcheck disable=SC2016 # workflow and compose expressions are matched literally
# Distribution contract of the MuckiSafe agent plugin
# (muckiware/mucki-safe-agent-plugin) in the MuckiSafe image:
#   - build arg AGENT_PLUGIN_VERSION, installed from Composer in the same
#     composer require as the other plugins, local checkouts never shadow it;
#   - the release dispatch muckisafe-agent-plugin-release pins exactly its
#     version and fails closed on a missing/foreign package or invalid ref;
#   - app and scheduler mount the same global host wakeup directory and get
#     MUWA_AGENT_ENCRYPTION_KEYRING; .env.example and README document both;
#   - the image contains no Go toolchain, agent binary or Go sources.
#
#   tests/agent-plugin-integration-test.sh [--image IMAGE]
#
# Without --image the built image is not inspected (static and behavioural
# checks only). Requires bash, jq and docker compose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly PACKAGE=muckiware/mucki-safe-agent-plugin
readonly EVENT=muckisafe-agent-plugin-release
readonly RESOLVER=.github/scripts/resolve-plugin-versions.sh
readonly WAKEUP_MOUNT='${MUCKI_AGENT_WAKEUP_PATH:-/var/lib/mucki-agent/wakeup}:/var/run/mucki-agent/wakeup'
readonly KEYRING='{"active":1,"keys":{"1":"0000000000000000000000000000000000000000000000000000000000000000"}}'
TMP_DIR="$(mktemp -d)"
readonly TMP_DIR
trap 'cleanup_probe; rm -rf "$TMP_DIR"' EXIT
IMAGE=""
FAILURES=0

cd "$REPO_ROOT"

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_contains() {
    grep -Fq -- "$2" "$1" 2>/dev/null || fail "$1 does not contain: $2"
}

# composer_require_block prints the Dockerfile RUN instruction that runs
# `composer require`, joined into one line.
composer_require_block() {
    awk '/^RUN / { block = ""; inside = 1 } inside { block = block " " $0 } inside && !/\\$/ { if (block ~ /composer require/) print block; inside = 0 }' docker/Dockerfile
}

# --- Dockerfile -------------------------------------------------------------

check_dockerfile() {
    local block
    assert_contains docker/Dockerfile 'ARG AGENT_PLUGIN_VERSION=*'
    block="$(composer_require_block)"
    # One composer require for all plugins: a version conflict fails the whole
    # resolution instead of leaving a half-updated plugin set.
    for required in \
        "muckiware/facility-plugin:\"\${FACILITY_PLUGIN_VERSION}\"" \
        "muckiware/facility-menu-plugin:\"\${FACILITY_MENU_PLUGIN_VERSION}\"" \
        "muckiware/log-plugin:\"\${LOG_PLUGIN_VERSION}\"" \
        "${PACKAGE}:\"\${AGENT_PLUGIN_VERSION}\""; do
        [[ "$block" == *"$required"* ]] || fail "the composer require of docker/Dockerfile does not install $required"
    done
    assert_contains docker/Dockerfile 'custom/plugins/MuckiSafeAgentPlugin'
    assert_contains .dockerignore 'muckidrive/custom/plugins/MuckiSafeAgentPlugin'
    if grep -Eiq 'golang|go build|/usr/local/go|mucki-agent' docker/Dockerfile; then
        fail "docker/Dockerfile installs Go or the host agent; the agent is released separately"
    fi
}

# --- release dispatch and version pinning -----------------------------------

# resolve EVENT_ACTION PACKAGE REF: runs the resolver like the publish workflow.
resolve() {
    EVENT_ACTION="$1" TRIGGER_PACKAGE="$2" TRIGGER_REF="$3" "./$RESOLVER"
}

check_publish_workflow() {
    local workflow=.github/workflows/docker-publish.yml
    assert_contains "$workflow" "- ${EVENT}"
    assert_contains "$workflow" "$RESOLVER"
    assert_contains "$workflow" 'AGENT_PLUGIN_VERSION=${{ env.AGENT_PLUGIN_VERSION }}'
    # Payload values reach the resolver through env, never interpolated.
    assert_contains "$workflow" 'TRIGGER_PACKAGE: ${{ github.event.client_payload.package }}'
    assert_contains "$workflow" 'TRIGGER_REF: ${{ github.event.client_payload.ref }}'
}

check_resolver() {
    if [ ! -x "$RESOLVER" ]; then
        fail "$RESOLVER is missing or not executable"
        return
    fi
    # Positive fixture: exactly the released version becomes the build arg,
    # every other plugin keeps floating.
    expect_pins "$EVENT v1.2.3" "$EVENT" "$PACKAGE" v1.2.3 \
        'AGENT_PLUGIN_VERSION=1.2.3' 'FACILITY_PLUGIN_VERSION=*' 'FACILITY_MENU_PLUGIN_VERSION=*' 'LOG_PLUGIN_VERSION=*'
    [ "$(resolve "$EVENT" "$PACKAGE" v1.2.3 2>/dev/null | grep -c .)" = 4 ] ||
        fail "the resolver must print exactly the four plugin version lines"
    expect_pins "$EVENT without v" "$EVENT" "$PACKAGE" 2.0.10 'AGENT_PLUGIN_VERSION=2.0.10'
    expect_pins "an untriggered build" '' '' '' 'AGENT_PLUGIN_VERSION=*' 'FACILITY_PLUGIN_VERSION=*'
    expect_pins "a facility release" muckifacility-plugin-release muckiware/facility-plugin v0.11.2 \
        'FACILITY_PLUGIN_VERSION=0.11.2' 'AGENT_PLUGIN_VERSION=*'
    check_resolver_rejects
}

# expect_pins DESCRIPTION EVENT_ACTION PACKAGE REF LINE...: the resolver
# accepts the trigger and prints every LINE.
expect_pins() {
    local description="$1" output line
    if ! output="$(resolve "$2" "$3" "$4" 2>&1)"; then
        fail "$description was rejected: $(tr '\n' ' ' <<<"$output")"
        return
    fi
    shift 4
    for line in "$@"; do
        grep -qxF -- "$line" <<<"$output" || fail "$description: expected '$line', got: $(tr '\n' ' ' <<<"$output")"
    done
}

check_resolver_rejects() {
    local -a cases=(
        "missing package||v1.2.3"
        "foreign package|muckiware/facility-plugin|v1.2.3"
        "similar package|muckiware/mucki-safe-agent-plugin-fork|v1.2.3"
        "missing ref|${PACKAGE}|"
        "branch ref|${PACKAGE}|main"
        "incomplete ref|${PACKAGE}|v1.2"
        "pre-release ref|${PACKAGE}|v1.2.3-rc.1"
        "injected ref|${PACKAGE}|v1.2.3;id"
    )
    local entry description package ref
    for entry in "${cases[@]}"; do
        IFS='|' read -r description package ref <<<"$entry"
        expect_rejected "$description" "$package" "$ref"
    done
    # A second line must never smuggle another pin into GITHUB_ENV.
    expect_rejected "newline ref" "$PACKAGE" "v1.2.3"$'\n'"FACILITY_PLUGIN_VERSION=0.1.0"
}

expect_rejected() {
    if resolve "$EVENT" "$2" "$3" >"$TMP_DIR/out" 2>&1; then
        fail "$EVENT with $1 was accepted: $(tr '\n' ' ' <"$TMP_DIR/out")"
    fi
}

# --- compose: wakeup mounts and keyring -------------------------------------

compose_config() {
    local wakeup_path="$1"
    : >"$TMP_DIR/empty.env"
    # Explicit file and env file: neither the local override nor a real .env
    # with secrets is read.
    env -i PATH="$PATH" HOME="$TMP_DIR" ${wakeup_path:+MUCKI_AGENT_WAKEUP_PATH="$wakeup_path"} \
        MUWA_AGENT_ENCRYPTION_KEYRING="$KEYRING" \
        docker compose --project-directory "$REPO_ROOT" -f docker-compose.yml --env-file "$TMP_DIR/empty.env" \
        config --format json 2>/dev/null
}

check_compose() {
    local count config custom
    count="$(grep -Fc -- "- ${WAKEUP_MOUNT}" docker-compose.yml || true)"
    [ "$count" = 2 ] || fail "docker-compose.yml must contain the wakeup mount exactly twice (app, scheduler), found $count"
    if ! command -v docker >/dev/null || ! config="$(compose_config '')"; then
        fail "docker compose config failed for docker-compose.yml"
        return
    fi
    custom="$(compose_config /srv/agent-wakeup)" || custom='{}'
    check_wakeup_services "$config" /var/lib/mucki-agent/wakeup
    check_wakeup_services "$custom" /srv/agent-wakeup
    for service in app scheduler; do
        [ "$(jq -r --arg s "$service" '.services[$s].environment.MUWA_AGENT_ENCRYPTION_KEYRING // empty' <<<"$config")" = "$KEYRING" ] ||
            fail "service $service does not receive MUWA_AGENT_ENCRYPTION_KEYRING unchanged"
    done
}

# check_wakeup_services CONFIG SOURCE: exactly app and scheduler bind SOURCE.
check_wakeup_services() {
    local services
    services="$(jq -r --arg source "$2" '.services | to_entries[]
        | select(any(.value.volumes[]?; .type == "bind" and .source == $source and .target == "/var/run/mucki-agent/wakeup"))
        | .key' <<<"$1" | sort | tr '\n' ' ')"
    [ "$services" = "app scheduler " ] || fail "wakeup bind mount $2 -> /var/run/mucki-agent/wakeup must be in exactly app and scheduler, found in: ${services:-none}"
    if jq -e '.services | to_entries[] | .value.volumes[]? | select(.target == "/var/run/mucki-agent/wakeup" and (.read_only // false))' <<<"$1" >/dev/null; then
        fail "the wakeup mount must be writable for www-data"
    fi
}

# --- documentation ----------------------------------------------------------

check_documentation() {
    assert_contains .env.example 'MUWA_AGENT_ENCRYPTION_KEYRING='
    assert_contains .env.example 'MUCKI_AGENT_WAKEUP_PATH='
    for text in "$PACKAGE" MuckiSafeAgentPlugin AGENT_PLUGIN_VERSION "$EVENT" MUWA_AGENT_ENCRYPTION_KEYRING MUCKI_AGENT_WAKEUP_PATH \
        'install -d -o root -g 33 -m 0770 /var/lib/mucki-agent/wakeup'; do
        assert_contains README.md "$text"
    done
    assert_contains README.md 'docs/host-agent/README.md'
    check_host_agent_documentation
}

# The host installation guide: release download with checksum, systemd,
# root-owned files, HTTPS by default, the global wakeup path, no Go on the
# host and the release dispatch.
check_host_agent_documentation() {
    local doc=docs/host-agent/README.md
    for text in \
        'https://github.com/muckiware/MuckiSafeAgentPlugin/releases' \
        'agent-vX.Y.Z' \
        'mucki-agent-X.Y.Z-linux.tar.gz.sha256' \
        'sha256sum --check --strict' \
        'install.sh' 'uninstall.sh' \
        'systemctl status mucki-agent' 'journalctl -u mucki-agent' \
        '/etc/mucki-agent/config.yaml' '/etc/mucki-agent/secret' '/etc/mucki-agent/policy.yaml' \
        '/var/lib/mucki-agent/state' 'root:root' '0600' \
        'allowInsecureHttp: true' 'https://' \
        '/var/lib/mucki-agent/wakeup' '/var/run/mucki-agent/wakeup' MUCKI_AGENT_WAKEUP_PATH \
        'mucki-agent config validate' \
        'No Go toolchain' \
        "$EVENT"; do
        assert_contains "$doc" "$text"
    done
}

# --- built image ------------------------------------------------------------

check_image() {
    if [ -z "$IMAGE" ]; then
        echo "SKIP: image checks (pass --image IMAGE after building it)"
        return
    fi
    local script
    script="$(cat <<'EOF'
set -u
cd /var/www/html
! command -v go >/dev/null || { echo "go toolchain present"; exit 1; }
test ! -e /usr/local/bin/mucki-agent || { echo "agent binary present"; exit 1; }
test -d vendor/muckiware/mucki-safe-agent-plugin || { echo "plugin not installed from composer"; exit 1; }
! find vendor/muckiware/mucki-safe-agent-plugin -type f \( -name '*.go' -o -name go.mod -o -name go.sum -o -name 'mucki-agent*' \) -print -quit | grep -q . \
    || { echo "Go sources or agent binary in the plugin package"; exit 1; }
COMPOSER_HOME=/tmp/composer composer show --locked muckiware/mucki-safe-agent-plugin >/dev/null || { echo "package not locked"; exit 1; }
grep -q '^muckiware/mucki-safe-agent-plugin ' .muckisafe-versions || { echo "package missing in .muckisafe-versions"; exit 1; }
EOF
)"
    docker run --rm --entrypoint bash "$IMAGE" -c "$script" >"$TMP_DIR/image.log" 2>&1 ||
        fail "image $IMAGE: $(tr '\n' ' ' <"$TMP_DIR/image.log")"
    check_wakeup_write
}

# --- wakeup write probe -----------------------------------------------------

readonly PROBE_PROJECT="muckisafe-wakeup-probe-$$"
PROBE_STARTED=false

# probe_compose ARGS...: docker compose with IMAGE for app and scheduler, the
# probe directory as wakeup path and an own project (no real volumes touched).
# Only the docker client settings pass through, so the same daemon as for
# `docker run` is used (rootless, contexts); no real .env is read.
probe_compose() {
    env -i PATH="$PATH" HOME="$TMP_DIR" MUCKI_AGENT_WAKEUP_PATH="$TMP_DIR/wakeup" \
        DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
        ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} \
        docker compose --project-directory "$REPO_ROOT" -p "$PROBE_PROJECT" \
        -f docker-compose.yml -f "$TMP_DIR/probe.override.yml" --env-file "$TMP_DIR/empty.env" "$@"
}

# probe_directory SCRIPT: runs SCRIPT as root on the probe directory (/probe)
# inside a container, so the host needs no sudo.
probe_directory() {
    docker run --rm --user 0 --entrypoint sh -v "$TMP_DIR/wakeup:/probe" "$IMAGE" -c "$1"
}

# cleanup_probe: removes the probe project and opens the probe directory for
# the EXIT trap. Runs on every exit, also after Ctrl+C. chmod instead of chown:
# with rootless docker or userns-remap a chown maps to a foreign host owner.
cleanup_probe() {
    [ "$PROBE_STARTED" = true ] || return 0
    probe_compose down --volumes >/dev/null 2>&1 || true
    probe_directory 'rm -rf /probe/* && chmod 0777 /probe' >/dev/null 2>&1 || true
}

# check_wakeup_write: app and scheduler write a wakeup file as www-data into
# a directory provisioned like install.sh does it (root:33, 0770). Proves the
# ownership contract only on Linux: Docker Desktop (macOS/Windows) does not
# enforce host directory ownership on bind mounts.
check_wakeup_write() {
    mkdir -p "$TMP_DIR/wakeup"
    : >"$TMP_DIR/empty.env"
    printf 'services:\n  app:\n    image: "%s"\n  scheduler:\n    image: "%s"\n' "$IMAGE" "$IMAGE" >"$TMP_DIR/probe.override.yml"
    PROBE_STARTED=true
    if ! probe_directory 'chown 0:33 /probe && chmod 0770 /probe' >"$TMP_DIR/probe.log" 2>&1; then
        fail "cannot prepare the wakeup probe directory: $(tr '\n' ' ' <"$TMP_DIR/probe.log")"
        return
    fi
    # Same steps as WakeupWriter: temp file, then rename to <id>.ready.
    local probe='set -e; [ "$(id -un)" = www-data ]; cd /var/run/mucki-agent/wakeup; : > "probe-$$.tmp"; mv "probe-$$.tmp" "probe-$$.ready"; rm "probe-$$.ready"'
    probe_compose run --rm --no-deps -T --user www-data --entrypoint sh app -c "$probe" >"$TMP_DIR/probe.log" 2>&1 ||
        fail "app cannot write wakeup files as www-data: $(tail -n 3 "$TMP_DIR/probe.log" | tr "\n" " ")"
    # The scheduler runs as www-data by itself: no --user override.
    probe_compose run --rm --no-deps -T --entrypoint sh scheduler -c "$probe" >"$TMP_DIR/probe.log" 2>&1 ||
        fail "scheduler cannot write wakeup files as www-data: $(tail -n 3 "$TMP_DIR/probe.log" | tr "\n" " ")"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --image) IMAGE="$2"; shift 2 ;;
            *) echo "usage: $0 [--image IMAGE]" >&2; exit 2 ;;
        esac
    done
    command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
    check_dockerfile
    check_publish_workflow
    check_resolver
    check_compose
    check_documentation
    check_image
    if [ "$FAILURES" -gt 0 ]; then
        echo "Agent plugin distribution contract: $FAILURES failure(s)" >&2
        exit 1
    fi
    echo "Agent plugin distribution contract tests passed"
}

main "$@"
