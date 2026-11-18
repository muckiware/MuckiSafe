#!/usr/bin/env bash
# =====================================================================
# jellyfin-service.sh — stoppt/startet den nativen Jellyfin-Service
#
# Aufruf:  jellyfin-service.sh {stop|start|restart|status}
#
# 'stop'  wartet, bis der Service WIRKLICH beendet ist (systemd + Prozess-
#         Check) — erst dann ist die SQLite-Datenbank (jellyfin.db samt
#         -wal/-shm) garantiert geflushed und für ein File-Backup konsistent.
# 'start' wartet, bis Jellyfin wieder per HTTP antwortet, und meldet die
#         Server-Version. Beide Aktionen sind idempotent.
#
# Exit-Codes: 0 = OK · 1 = Fehler/Timeout · 2 = ungültige Benutzung ·
#             3 = status: Service nicht aktiv
#
# Benötigt root oder passwortloses sudo (systemctl).
#
# Konfiguration über Umgebungsvariablen (Defaults):
#   SERVICE=jellyfin      systemd-Unit-Name
#   PORT=8096             HTTP-Port für den Start-Healthcheck
#   TIMEOUT_STOP=30       max. Sekunden auf das Beenden warten
#   TIMEOUT_START=120     max. Sekunden auf HTTP-Bereitschaft warten
#
# Manuell:   sudo /usr/local/sbin/jellyfin-service.sh stop
# MuckiSafe: wird über /usr/local/bin/muckisafe-jellyfin-control aufgerufen
#            (Flag-Datei + systemd path unit — siehe ANLEITUNG.md).
# =====================================================================
set -uo pipefail

SERVICE="${SERVICE:-jellyfin}"
PORT="${PORT:-8096}"
TIMEOUT_STOP="${TIMEOUT_STOP:-30}"
TIMEOUT_START="${TIMEOUT_START:-120}"
URL="http://127.0.0.1:${PORT}/System/Info/Public"

say() { echo "[$(date '+%F %T')] $*"; }

[ -n "$SERVICE" ] || { say "FEHLER: SERVICE darf nicht leer sein."; exit 2; }
for v in PORT TIMEOUT_STOP TIMEOUT_START; do
  case "${!v}" in
    ''|*[!0-9]*) say "FEHLER: \$${v} muss numerisch sein ('${!v}')."; exit 2 ;;
  esac
done

# --- Rechte: root oder passwortloses sudo ----------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  sudo -n true 2>/dev/null || { say "FEHLER: Ohne root-Rechte kein systemctl (sudo -n nicht verfügbar)."; exit 1; }
  SUDO="sudo -n"
fi

svc() { $SUDO systemctl "$@"; }
is_running() { svc is-active --quiet "$SERVICE"; }

server_version() {
  curl -fsS --max-time 3 "$URL" 2>/dev/null | grep -o '"Version":"[^"]*"' | cut -d'"' -f4 || true
}

# --- Warten, bis wirklich gestoppt -----------------------------------
wait_stopped() {
  local waited=0
  while is_running || pgrep -x "$SERVICE" >/dev/null 2>&1; do
    if [ "$waited" -ge "$TIMEOUT_STOP" ]; then return 1; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# --- Warten, bis der HTTP-Endpunkt antwortet --------------------------
wait_ready() {
  local waited=0
  while ! curl -fsS --max-time 2 "$URL" -o /dev/null 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT_START" ]; then return 1; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

do_stop() {
  if ! is_running; then
    say "Service '${SERVICE}' läuft bereits nicht — nichts zu tun."
    return 0
  fi
  say "Stoppe '${SERVICE}' ..."
  svc stop "$SERVICE" || { say "FEHLER: systemctl stop fehlgeschlagen."; return 1; }
  if wait_stopped; then
    say "'${SERVICE}' sauber gestoppt — keine Prozesse mehr aktiv, DB konsistent."
    return 0
  fi
  say "FEHLER: '${SERVICE}' wurde innerhalb von ${TIMEOUT_STOP}s nicht vollständig beendet."
  return 1
}

do_start() {
  if is_running; then
    say "Service '${SERVICE}' läuft bereits — prüfe nur die Erreichbarkeit."
  else
    say "Starte '${SERVICE}' ..."
    svc start "$SERVICE" || { say "FEHLER: systemctl start fehlgeschlagen."; return 1; }
  fi
  if wait_ready; then
    local ver; ver="$(server_version)"
    say "'${SERVICE}' ist wieder erreichbar${ver:+ (Version: ${ver})}."
    return 0
  fi
  say "FEHLER: '${SERVICE}' antwortet nach ${TIMEOUT_START}s nicht auf ${URL} — bitte prüfen (journalctl -u ${SERVICE})!"
  return 1
}

do_restart() {
  do_stop || return 1
  do_start
}

do_status() {
  if is_running; then
    local ver; ver="$(server_version)"
    say "AKTIV${ver:+ (Version: ${ver})}"
    return 0
  fi
  say "INAKTIV"
  return 3
}

usage() {
  cat <<EOF
Aufruf: $0 {stop|start|restart|status}
  stop     anhalten, bis kein Prozess mehr läuft (idempotent)
  start    starten und auf HTTP-Bereitschaft warten (idempotent)
  restart  stop + start
  status   Zustand ausgeben (Exit 0 = aktiv, 3 = inaktiv)
Env: SERVICE=${SERVICE} PORT=${PORT} TIMEOUT_STOP=${TIMEOUT_STOP} TIMEOUT_START=${TIMEOUT_START}
EOF
  exit "${1:-2}"
}

case "${1:-}" in
  stop)    do_stop ;;
  start)   do_start ;;
  restart) do_restart ;;
  status)  do_status ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
