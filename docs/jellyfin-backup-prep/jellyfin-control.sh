#!/bin/bash
# =====================================================================
# jellyfin-control.sh — Jellyfin stoppen/starten fürs MuckiSafe-Backup
#                        (Container-Seite)
#
# Aufruf: von der MuckiSafe-Backup-Konfiguration als BATCH-Befehl:
#   VOR dem Backup:   Befehl /scripts/jellyfin-control.sh  Argumente: stop
#   NACH dem Backup:  Befehl /scripts/jellyfin-control.sh  Argumente: start
# (Test manuell: docker compose exec -u www-data app /scripts/jellyfin-control.sh stop)
#
# Wirkung: legt eine Trigger-Datei im SCRIPTS_PATH-Mount ab → die systemd-
# path-Unit auf dem Host führt aus:
#   stop : jellyfin-service.sh stop + Lese-ACLs (u:33:rX) auf die
#          Jellyfin-Verzeichnisse (damit restic als UID 33 lesen kann)
#   start: jellyfin-service.sh start (wartet auf HTTP-Bereitschaft)
# Dieses Skript wartet auf den Done-Marker des Hosts und verifiziert bei
# 'stop', dass der Backup-User die Daten tatsächlich lesen kann.
#
# Fehler-Kompensation: Schlägt der 'stop'-Weg fehl (Host-Fehler, Marker-
# Mismatch, Verifikation), schiebt das Skript automatisch einen 'start'
# nach (Best-Effort), bevor es mit Exit 1 abbricht — Jellyfin bleibt dann
# nicht die Nacht unten. Ein fehlgeschlagener 'start' nach dem Backup
# bleibt Exit 1: Das Backup ist fertig, aber du willst sehen, dass
# Jellyfin nicht zurückkam.
#
# Exit 0 = weiter (Backup kann starten bzw. Jellyfin läuft wieder)
# Exit 1 = fehlgeschlagen — Backup-Konfiguration sollte abbrechen.
# =====================================================================
set -uo pipefail

PREP_DIR="${PREP_DIR:-/scripts/.jellyfin}"   # über SCRIPTS_PATH-Mount mit dem Host geteilt
PREP_TIMEOUT="${PREP_TIMEOUT:-600}"          # Sekunden max. auf den Host warten
JF_LIB="${JF_LIB:-/var/lib/jellyfin}"        # Container-Sicht auf die Jellyfin-Daten

RUN_FILE="$PREP_DIR/run"
DONE_FILE="$PREP_DIR/done"
ERR_FILE="$PREP_DIR/err"

log(){ echo "[jellyfin-control] $*"; }
die(){ echo "[jellyfin-control] FEHLER: $*" >&2; exit 1; }

ACTION="${1:-}"
case "$ACTION" in
  stop|start) ;;
  *) die "Aufruf: $0 stop|start" ;;
esac

mkdir -p "$PREP_DIR" 2>/dev/null || die "Kann $PREP_DIR nicht anlegen — SCRIPTS_PATH-Mount vorhanden und Ordner 33:33?"

# --- Trigger an den Host senden und auf das Ergebnis warten ---------------
# host_action stop|start → Exit 0 = Host hat bestätigt, 1 = fehlgeschlagen
host_action() {
    local action="$1" marker waited host_marker
    marker="$(date +%s)-$$"
    rm -f "$DONE_FILE" "$ERR_FILE" 2>/dev/null
    printf '%s %s\n' "$action" "$marker" > "$RUN_FILE" || { log "Kann Trigger-Datei $RUN_FILE nicht schreiben (Rechte auf $PREP_DIR?)"; return 1; }
    log "Trigger '$action' gesetzt ($marker) — Host arbeitet (max. ${PREP_TIMEOUT}s warten)..."

    waited=0
    while [ ! -s "$DONE_FILE" ] && [ ! -s "$ERR_FILE" ]; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge "$PREP_TIMEOUT" ]; then
            rm -f "$RUN_FILE"
            log "Host hat nicht reagiert (muckisafe-jellyfin.path installiert und aktiv? Host: journalctl -u muckisafe-jellyfin.service)"
            return 1
        fi
    done

    if [ -s "$ERR_FILE" ]; then
        sed 's/^/[jellyfin-control] HOST-FEHLER: /' "$ERR_FILE" >&2
        rm -f "$RUN_FILE" "$ERR_FILE" "$DONE_FILE"
        return 1
    fi

    host_marker="$(tail -n 1 "$DONE_FILE" 2>/dev/null)"
    if [ "$host_marker" != "$marker" ]; then
        log "Done-Marker '$host_marker' passt nicht zum Trigger '$marker' — paralleler Lauf?"
        rm -f "$RUN_FILE" "$DONE_FILE"
        return 1
    fi
    rm -f "$RUN_FILE" "$DONE_FILE"
    return 0
}

# --- Lesbarkeit als Backup-User (UID 33) prüfen ---------------------------
# Läuft dieses Skript als root, simuliert setpriv den Backup-User, damit
# die Prüfung nicht fälschlich grün wird. Als www-data (Normalfall im
# Backup) prüft der direkte test -r exakt die Sicht des Backup-Prozesses.
readable_as33() {
    if [ "$(id -u)" = "0" ] && command -v setpriv >/dev/null 2>&1; then
        setpriv --reuid=33 --regid=33 --clear-groups sh -c 'test -r "$1"' _ "$1"
    else
        test -r "$1"
    fi
}

# --- Best-Effort-Kompensation: Jellyfin wieder hochfahren ----------------
compensate_start() {
    log "Stop-Weg fehlgeschlagen — Jellyfin wieder hochfahren (Best-Effort)..."
    if host_action start; then
        log "Jellyfin läuft wieder (Fehler-Kompensation)."
    else
        log "WARNUNG: Jellyfin konnte NICHT wieder gestartet werden — manuell prüfen: sudo systemctl start jellyfin"
    fi
}

# ========================================================================
if host_action "$ACTION"; then
    log "Host-Arbeit erledigt."
else
    if [ "$ACTION" = "stop" ]; then
        compensate_start
        die "Jellyfin ließ sich nicht stoppen — Backup NICHT starten"
    fi
    die "Jellyfin startet nach dem Backup nicht — manuell prüfen: systemctl status jellyfin"
fi

if [ "$ACTION" = "stop" ]; then
    verify_ok=1
    if [ -d "$JF_LIB" ]; then
        # Kritischste Datei ist die DB; liegt sie woanders konfiguriert
        # (database.xml), prüfen wir wenigstens das data-Verzeichnis.
        CHECK_TARGET="$JF_LIB/data/jellyfin.db"
        [ -e "$CHECK_TARGET" ] || CHECK_TARGET="$JF_LIB/data"
        for f in "$JF_LIB" "$CHECK_TARGET"; do
            if [ ! -e "$f" ]; then
                log "$f existiert im Container nicht — Mount der Backup-Quelle prüfen."
                verify_ok=0
                break
            fi
            if ! readable_as33 "$f"; then
                log "$f ist für den Backup-User (UID 33) nicht lesbar — setfacl auf dem Host gelaufen?"
                verify_ok=0
                break
            fi
        done
        [ "$verify_ok" = 1 ] && log "Verifikation OK: $JF_LIB für UID 33 lesbar."
    else
        log "WARNUNG: $JF_LIB ist im Container nicht gemountet — Backup-Quellen im MuckiSafe prüfen."
    fi
    if [ "$verify_ok" = 1 ]; then
        log "Jellyfin gestoppt, DB konsistent — Backup kann starten."
        exit 0
    fi
    compensate_start
    die "Vor-Backup-Verifikation fehlgeschlagen — Backup NICHT starten"
else
    log "Jellyfin läuft wieder."
    exit 0
fi
