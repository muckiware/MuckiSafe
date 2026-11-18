#!/bin/bash
# =====================================================================
# bitwarden-prep.sh — Vorbereitung für das Bitwarden-Backup (Container-Seite)
#
# Aufruf: von der MuckiSafe-Backup-Konfiguration VOR dem restic-Backup
#         (Test manuell: docker compose exec -u www-data app /scripts/bitwarden-prep.sh)
#
# Wirkung:
#   1. Legt eine Trigger-Datei im /scripts-Mount ab → die systemd-path-Unit
#      auf dem Host führt aus:
#        - frische MSSQL-Vollsicherung: docker exec bitwarden-mssql /backup-db.sh
#        - Lese-ACLs für den Backup-User: setfacl -R -m u:33:rX /opt/bitwarden
#   2. Wartet auf das Ergebnis und verifiziert, dass das restore-kritische
#      Set als UID 33 (www-data) lesbar ist — BEVOR restic losläuft.
#
# Exit 0 = Backup kann starten. Exit 1 = Vorbereitung fehlgeschlagen
#          (Backup-Konfiguration sollte dann abbrechen, sonst Exit-3-Backup).
# =====================================================================
set -uo pipefail

PREP_DIR="${PREP_DIR:-/scripts/.prep}"           # über SCRIPTS_PATH-Mount mit dem Host geteilt
PREP_TIMEOUT="${PREP_TIMEOUT:-600}"               # Sekunden max. auf den Host warten
BW_DATA="${BW_DATA:-/opt/bitwarden/bwdata}"       # Container-Sicht auf die Bitwarden-Daten

RUN_FILE="$PREP_DIR/run"
DONE_FILE="$PREP_DIR/done"
ERR_FILE="$PREP_DIR/err"

log(){ echo "[bitwarden-prep] $*"; }
die(){ echo "[bitwarden-prep] FEHLER: $*" >&2; exit 1; }

[ -d "$BW_DATA" ] || die "Bitwarden-Daten nicht gefunden: $BW_DATA (BITWARDEN_PATH-Mount prüfen)"
mkdir -p "$PREP_DIR" 2>/dev/null || die "Kann $PREP_DIR nicht anlegen — Host-Ordner 'scripts' muss 33:33 gehören"

# --- Trigger an den Host schicken ---
MARKER="$(date +%s)-$$"
rm -f "$DONE_FILE" "$ERR_FILE" 2>/dev/null
printf '%s\n' "$MARKER" > "$RUN_FILE" || die "Kann Trigger-Datei $RUN_FILE nicht schreiben (Rechte auf $PREP_DIR?)"
log "Trigger gesetzt ($MARKER) — Host erzeugt jetzt frische .BAK + Lese-ACLs (max. ${PREP_TIMEOUT}s warten)..."

waited=0
while [ ! -s "$DONE_FILE" ] && [ ! -s "$ERR_FILE" ]; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$PREP_TIMEOUT" ]; then
        rm -f "$RUN_FILE"
        die "Host hat nicht reagiert (muckisafe-bitwarden-prep.path installiert und aktiv? Host: journalctl -u muckisafe-bitwarden-prep)"
    fi
done

if [ -s "$ERR_FILE" ]; then
    sed 's/^/[bitwarden-prep] HOST-FEHLER: /' "$ERR_FILE" >&2
    rm -f "$RUN_FILE" "$ERR_FILE" "$DONE_FILE"
    die "Host-seitige Vorbereitung fehlgeschlagen — Backup nicht starten"
fi

host_marker="$(tail -n 1 "$DONE_FILE" 2>/dev/null)"
if [ "$host_marker" != "$MARKER" ]; then
    die "Done-Marker '$host_marker' passt nicht zum Trigger '$MARKER' — paralleler Vorbereitungslauf? Backup erneut starten"
fi
rm -f "$RUN_FILE" "$DONE_FILE"
log "Host-Arbeit erledigt."

# --- Verifikation: restore-kritisches Set muss als Backup-User lesbar sein ---
# Läuft dieses Skript als root, simuliert setpriv den echten Backup-User (UID 33),
# damit die Prüfung nicht fälschlich grün wird.
if [ "$(id -u)" = "0" ] && command -v setpriv >/dev/null 2>&1; then
    AS33=(setpriv --reuid=33 --regid=33 --clear-groups)
else
    AS33=()
fi

check_readable(){ # $1 = Datei, $2 = Bezeichner
    local f="$1" label="$2"
    if [ "${#AS33[@]}" -gt 0 ]; then
        "${AS33[@]}" sh -c 'test -r "$1"' _ "$f" \
            || die "$label für UID 33 nicht lesbar: $f (setfacl auf dem Host gelaufen?)"
    else
        test -r "$f" || die "$label nicht lesbar: $f"
    fi
}

latest_bak="$(ls -1 "$BW_DATA/mssql/backups/"*.BAK 2>/dev/null | sort | tail -n 1)"
[ -n "$latest_bak" ] || die "Keine .BAK-Datei in $BW_DATA/mssql/backups/"
check_readable "$latest_bak"                      "Neueste DB-Vollsicherung"
check_readable "$BW_DATA/env/global.override.env" "env/global.override.env"
check_readable "$BW_DATA/identity/identity.pfx"    "identity/identity.pfx"
adp_key="$(ls -1 "$BW_DATA/core/aspnet-dataprotection/"*.xml 2>/dev/null | head -n 1)"
if [ -n "$adp_key" ]; then
    check_readable "$adp_key" "aspnet-dataprotection-Key"
else
    log "WARNUNG: keine aspnet-dataprotection-Keys in $BW_DATA/core/aspnet-dataprotection/ — Installation prüfen"
fi

log "Verifikation OK:"
log "  .BAK: $(basename "$latest_bak")"
log "  env/global.override.env, identity.pfx, dataprotection: lesbar für UID 33"
log "Vorbereitung abgeschlossen — Backup kann starten."
exit 0
