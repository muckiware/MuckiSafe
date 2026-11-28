#!/usr/bin/env bash
# Resolves the composer constraints of the MuckiSafe plugins for one image
# build and prints them as KEY=VALUE lines for $GITHUB_ENV.
#
#   EVENT_ACTION=<repository_dispatch type> TRIGGER_PACKAGE=<package> \
#   TRIGGER_REF=<vX.Y.Z> .github/scripts/resolve-plugin-versions.sh
#
# Every plugin defaults to "*": composer picks the newest stable release that
# fits the other plugins. Only the plugin whose release event triggered the
# build is pinned to exactly that version, so the build fails loudly instead
# of silently shipping an older one. A plugin release event fails closed: its
# payload must name exactly the plugin of that event and a release version.
# Other events (platform releases, pushes, manual runs) pin nothing.
#
# Payload values arrive through the environment only; nothing is evaluated.
set -euo pipefail

FACILITY_PLUGIN_VERSION='*'
FACILITY_MENU_PLUGIN_VERSION='*'
LOG_PLUGIN_VERSION='*'
AGENT_PLUGIN_VERSION='*'
MUCKISAFE_PLUGIN_VERSION='*'

EVENT_ACTION="${EVENT_ACTION:-}"
TRIGGER_PACKAGE="${TRIGGER_PACKAGE:-}"
TRIGGER_REF="${TRIGGER_REF:-}"

fail() {
    echo "::error::$*" >&2
    exit 1
}

# expected_package EVENT prints the only package an event may announce.
expected_package() {
    case "$1" in
        muckifacility-plugin-release)      echo muckiware/facility-plugin ;;
        muckifacility-menu-plugin-release) echo muckiware/facility-menu-plugin ;;
        muckilog-plugin-release)           echo muckiware/log-plugin ;;
        muckisafe-agent-plugin-release)    echo muckiware/mucki-safe-agent-plugin ;;
        muckisafe-plugin-release)          echo muckiware/muckisafe-plugin ;;
    esac
}

# pinned_version prints the validated version of the trigger without "v".
pinned_version() {
    local expected="$1"
    [ "$TRIGGER_PACKAGE" = "$expected" ] ||
        fail "${EVENT_ACTION} must announce ${expected}, got '${TRIGGER_PACKAGE}'."
    # [[ =~ ]] anchors the whole value, so a second line can never pass.
    [[ "$TRIGGER_REF" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        fail "Trigger ref '${TRIGGER_REF}' of ${expected} is not a release version (vX.Y.Z)."
    echo "${TRIGGER_REF#v}"
}

expected="$(expected_package "$EVENT_ACTION")"
if [ -n "$expected" ]; then
    version="$(pinned_version "$expected")"
    echo "Triggered by ${expected} ${version}." >&2
    case "$expected" in
        muckiware/facility-plugin)         FACILITY_PLUGIN_VERSION="$version" ;;
        muckiware/facility-menu-plugin)    FACILITY_MENU_PLUGIN_VERSION="$version" ;;
        muckiware/log-plugin)              LOG_PLUGIN_VERSION="$version" ;;
        muckiware/mucki-safe-agent-plugin) AGENT_PLUGIN_VERSION="$version" ;;
        muckiware/muckisafe-plugin)        MUCKISAFE_PLUGIN_VERSION="$version" ;;
    esac
fi

printf 'FACILITY_PLUGIN_VERSION=%s\n' "$FACILITY_PLUGIN_VERSION"
printf 'FACILITY_MENU_PLUGIN_VERSION=%s\n' "$FACILITY_MENU_PLUGIN_VERSION"
printf 'LOG_PLUGIN_VERSION=%s\n' "$LOG_PLUGIN_VERSION"
printf 'AGENT_PLUGIN_VERSION=%s\n' "$AGENT_PLUGIN_VERSION"
printf 'MUCKISAFE_PLUGIN_VERSION=%s\n' "$MUCKISAFE_PLUGIN_VERSION"
