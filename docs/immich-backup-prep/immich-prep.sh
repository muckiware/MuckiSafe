#!/bin/bash
# =====================================================================
# immich-prep.sh — Vorbereitung für das Immich-Backup (Container-Seite)
#
# Aufruf: von der MuckiSafe-Backup-Konfiguration VOR dem restic-Backup
#         (Test manuell: docker compose exec -u www-data app /scripts/immich-prep.sh)
#
# Wirkung:
#   1. Legt eine Trigger-Datei im /scripts-Mount ab → die systemd-path-Unit
#      auf dem Host führt aus:
#        - frischen Postgres-Dump (online konsistent, MVCC):
#          docker exec immich_postgres pg_dump --clean --if-exists | gzip
#          → <UPLOAD_LOCATION>/backups/immich-db-dump-manual-<ts>.sql.gz
#          (dort, wo auch Immichs eigene Auto-Backups liegen und die
#          Restore-UI beide findet)
#        - Lese-ACLs für den Backup-User: setfacl -R -m u:33:rX auf die
#          Immich-Datenpfade (Upload-Baum, plus thumbs/encoded-video/
#          profile, falls separate Host-Pfade)
#   2. Wartet auf das Ergebnis und verifiziert — BEVOR restic losläuft —,
#      dass der frische Dump und alle Quellpfade als UID 33 (www-data)
#      lesbar sind.
#
# Pfad-Wissen kommt vom Host: die Done-Datei enthält
#   Zeile 1   = Marker, Zeile 2 = Dump-Datei, Zeilen 3..n = Quellpfade.
# Der MuckiSafe-Container sieht die Immich-Daten nur über die 1:1-
# Bind-Mounts unter ihren echten Host-Pfaden — deshalb prüft dieses
# Skript genau die Pfade, die der Host geliefert hat, statt eigene
# Defaults zu raten.
#
# Exit 0 = Backup kann starten. Exit 1 = Vorbereitung fehlgeschlagen
#          (Backup-Konfiguration sollte dann abbrechen, sonst Exit-3-Backup).
# =====================================================================
set -uo pipefail

PREP_DIR="${PREP_DIR:-/scripts/.immich}"   # über SCRIPTS_PATH-Mount mit dem Host geteilt
PREP_TIMEOUT="${PREP_TIMEOUT:-600}"        # Sekunden max. auf den Host warten

RUN_FILE="$PREP_DIR/run"
DONE_FILE="$PREP_DIR/done"
ERR_FILE="$PREP_DIR/err"

log(){ echo "[immich-prep] $*"; }
die(){ echo "[immich-prep] FEHLER: $*" >&2; exit 1; }

mkdir -p "$PREP_DIR" 2>/dev/null || die "Kann $PREP_DIR nicht anlegen — Host-Ordner 'scripts' muss 33:33 gehören"

# --- Trigger an den Host schicken ---
MARKER="$(date +%s)-$$"
rm -f "$DONE_FILE" "$ERR_FILE" 2>/dev/null
printf '%s\n' "$MARKER" > "$RUN_FILE" || die "Kann Trigger-Datei $RUN_FILE nicht schreiben (Rechte auf $PREP_DIR?)"
log "Trigger gesetzt ($MARKER) — Host erzeugt jetzt frischen DB-Dump + Lese-ACLs (max. ${PREP_TIMEOUT}s warten)..."

waited=0
while [ ! -s "$DONE_FILE" ] && [ ! -s "$ERR_FILE" ]; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$PREP_TIMEOUT" ]; then
        rm -f "$RUN_FILE"
        die "Host hat nicht reagiert (muckisafe-immich-prep.path installiert und aktiv? Host: journalctl -u muckisafe-immich-prep)"
    fi
done

if [ -s "$ERR_FILE" ]; then
    sed 's/^/[immich-prep] HOST-FEHLER: /' "$ERR_FILE" >&2
    rm -f "$RUN_FILE" "$ERR_FILE" "$DONE_FILE"
    die "Host-seitige Vorbereitung fehlgeschlagen — Backup nicht starten"
fi

# Done-Datei auslesen: Zeile 1 = Marker, Zeile 2 = Dump, Zeilen 3..n = Quellpfade
host_marker="$(sed -n '1p' "$DONE_FILE")"
if [ "$host_marker" != "$MARKER" ]; then
    rm -f "$RUN_FILE" "$DONE_FILE"
    die "Done-Marker '$host_marker' passt nicht zum Trigger '$MARKER' — paralleler Vorbereitungslauf? Backup erneut starten"
fi
DUMP_FILE="$(sed -n '2p' "$DONE_FILE")"
VERIFY_PATHS="$(sed -n '3,$p' "$DONE_FILE")"
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

check_readable(){ # $1 = Datei/Ordner, $2 = Bezeichner
    local f="$1" label="$2"
    if [ "${#AS33[@]}" -gt 0 ]; then
        "${AS33[@]}" sh -c 'test -r "$1"' _ "$f" \
            || die "$label für UID 33 nicht lesbar: $f (setfacl auf dem Host gelaufen? Bind-Mount im MuckiSafe vorhanden?)"
    else
        test -r "$f" || die "$label nicht lesbar: $f"
    fi
}

[ -n "$DUMP_FILE" ] || die "Done-Datei enthält keinen Dump-Pfad — Host-Skript defekt/alt?"
[ -f "$DUMP_FILE" ] || die "Frischer DB-Dump fehlt im Container: $DUMP_FILE (UPLOAD_LOCATION 1:1 in MuckiSafe gemountet?)"
[ -s "$DUMP_FILE" ] || die "DB-Dump ist leer: $DUMP_FILE"
check_readable "$DUMP_FILE" "Neueste DB-Sicherung"

src_count=0
if [ -z "$VERIFY_PATHS" ]; then
    log "WARNUNG: Host lieferte keine Quellpfade — nur den Dump verifiziert."
else
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || die "Quellpfad existiert im Container nicht: $p (Bind-Mount in MuckiSafe prüfen)"
        check_readable "$p" "Immich-Datenpfad"
        src_count=$((src_count + 1))
    done <<< "$VERIFY_PATHS"
fi

log "Verifikation OK:"
log "  DB-Dump: $(basename "$DUMP_FILE")"
[ "$src_count" -gt 0 ] && log "  $src_count Quellpfad(e) für UID 33 lesbar"
log "Vorbereitung abgeschlossen — Backup kann starten."
exit 0
