# Preparing Jellyfin backups — stop/start hooks around the backup

This folder contains an event-coupled stop/start wrapper for MuckiFacilityPlugin
restic backups of a **natively installed Jellyfin server** (Debian/Ubuntu
package with systemd, data in `/var/lib/jellyfin`, config in `/etc/jellyfin`).
Wire it into the backup configuration of your `jellyfin` repository and it
**stops the service right before every backup and starts it again afterwards**:

1. **stop (pre-backup)** — `systemctl stop jellyfin` (including a wait loop
   until no process is left) + `setfacl -R -m u:33:rX` on `/var/lib/jellyfin`
   and `/etc/jellyfin`. Only a stopped server guarantees a consistent SQLite
   database: Jellyfin holds `jellyfin.db` (with its `-wal`/`-shm` files —
   playlists, collections, users and watch state live there) with exclusive
   locks; a file copy of the running database is inconsistent and may not
   restore. The ACL grant makes the data readable for the backup user
   (`www-data`, UID 33), whose restic would otherwise save an **incomplete**
   snapshot and exit with code 3 (`at least one source file could not be
   read`) — missing exactly the database.
2. **start (post-backup)** — `systemctl start jellyfin` (including a wait loop
   until the HTTP port answers, so "started" means usable again).

Media files are **not** part of this pattern — the Jellyfin data and config
directories are tiny compared to a media library. Back the library up
separately, as usual.

## Why the detour through the host?

The pre/post-backup commands run **inside the MuckiSafe container as
`www-data`**. In the container there is no `systemctl` (the Jellyfin service
lives on the Docker host) and no `setfacl`. Instead, the container script
drops a marker file into the `scripts` bind mount (see `SCRIPTS_PATH` in
`docker-compose.override.yml`, mounted into both `app` and `scheduler` at
`/scripts`). A systemd **path unit** on the host watches that file and runs
the host-side script as root. No SSH, no keys, no Docker socket — just the
shared mount you already have.

```
┌─────────── MuckiSafe container (www-data) ───────────┐
│ jellyfin-control.sh stop|start                         │
│   1. write /scripts/.jellyfin/run (action + marker)    │
│   2. poll /scripts/.jellyfin/done (max. PREP_TIMEOUT s)│
│   3. stop only: verify data readable as UID 33         │
│   exit 0 → backup starts / backup run complete         │
└──────────────┬─────────────────────────────────────────┘
               │ shared SCRIPTS_PATH bind mount
┌──────────────▼────────────── Docker host (root) ──────┐
│ systemd path unit  →  muckisafe-jellyfin-control        │
│   stop : jellyfin-service.sh stop + setfacl -R u:33:rX  │
│   start: jellyfin-service.sh start (waits for HTTP)     │
│   write done marker, remove trigger                     │
└────────────────────────────────────────────────────────┘
```

## Files

| File | Goes to |
|---|---|
| `jellyfin-control.sh` | `<scripts host dir>/jellyfin-control.sh` — container side, registered in the backup configuration (visible in the container as `/scripts/jellyfin-control.sh`) |
| `jellyfin-service.sh` | `/usr/local/sbin/jellyfin-service.sh` — host side, the actual stop/start utility (also usable standalone: `{stop\|start\|restart\|status}`) |
| `muckisafe-jellyfin-control` | `/usr/local/bin/muckisafe-jellyfin-control` — host side, consumes the trigger file |
| `muckisafe-jellyfin.path` | `/etc/systemd/system/` — watches the trigger file |
| `muckisafe-jellyfin.service` | `/etc/systemd/system/` — runs the host script |

## Installation (all on the Docker host)

```bash
# 0) Prerequisites
which setfacl || sudo apt-get install -y acl

# 1) Determine the host path of the scripts directory (STACK_SCRIPTS).
#    It is the source of the /scripts bind mount from docker-compose.override.yml:
docker inspect "$(docker compose ps -q app)" --format '{{json .Mounts}}' | python3 -m json.tool | less
#    → look for Destination "/scripts" → Source, e.g. /srv/muckisafe/scripts

# 2) Copy the files to their destinations (adjust paths!)
sudo cp jellyfin-service.sh /usr/local/sbin/
sudo cp muckisafe-jellyfin-control /usr/local/bin/
sudo cp muckisafe-jellyfin.path muckisafe-jellyfin.service /etc/systemd/system/
cp jellyfin-control.sh "$STACK_SCRIPTS/"

# 3) Replace the @STACK_SCRIPTS@ placeholder in BOTH unit files:
sudo sed -i "s|@STACK_SCRIPTS@|$STACK_SCRIPTS|g" \
  /etc/systemd/system/muckisafe-jellyfin.{path,service}
# Jellyfin data elsewhere / different unit name / other HTTP port?
#   → JF_ACL_TARGETS and JELLYFIN_SERVICE_BIN in the .service;
#     jellyfin-service.sh itself takes SERVICE / PORT env overrides
#     (defaults: unit "jellyfin", port 8096).

# 4) Permissions: the container user (UID 33) must be able to write into the
#    scripts directory; scripts themselves only need read+execute:
sudo chmod 755 /usr/local/sbin/jellyfin-service.sh \
               /usr/local/bin/muckisafe-jellyfin-control \
               "$STACK_SCRIPTS/jellyfin-control.sh"

# 5) Activate the units:
sudo systemctl daemon-reload
sudo systemctl enable --now muckisafe-jellyfin.path
systemctl status muckisafe-jellyfin.path   # must show 'active (waiting)'
```

### Bind mounts for the backup source

restic runs inside the MuckiSafe containers — the Jellyfin data must be
mounted into **both** `app` and `scheduler` (`docker-compose.override.yml`):

```yaml
  app:
    volumes:
      - /var/lib/jellyfin:/var/lib/jellyfin:ro
      - /etc/jellyfin:/etc/jellyfin:ro
  scheduler:
    volumes:
      - /var/lib/jellyfin:/var/lib/jellyfin:ro
      - /etc/jellyfin:/etc/jellyfin:ro
```

Same paths inside and outside the container, so the restic snapshot paths
match the original ones on restore. `:ro` is safe: restores go through the
separate restore-repository mount. Apply with `docker compose up -d` (a
restart does not pick up new mounts).

## Test (before wiring it into MuckiSafe)

Run the container script **as the backup user, not as root** — a root test
would be a false green:

```bash
cd <your muckisafe stack directory>

systemctl status jellyfin                                   # should be running
docker compose exec -u www-data app /scripts/jellyfin-control.sh stop
systemctl status jellyfin                                    # must show 'inactive'
docker compose exec -u www-data app /scripts/jellyfin-control.sh start
systemctl status jellyfin                                    # must show 'active (running)'
```

Expected output (the **first reaction can take up to ~30 s** — systemd
re-checks the path condition periodically in addition to inotify):

```
[jellyfin-control] Trigger 'stop' set (1763...-123) — host is working (waiting up to 600s)...
[jellyfin-control] Host work done.
[jellyfin-control] Verification OK: /var/lib/jellyfin readable for UID 33.
[jellyfin-control] Jellyfin stopped, DB consistent — the backup can start.
```

Host-side log: `journalctl -u muckisafe-jellyfin.service`

## Wiring into MuckiSafe

In the backup configuration of the `jellyfin` repository register the script
twice (type `BATCH` both times):

| Field | Before the backup | After the backup |
|---|---|---|
| Command | `/scripts/jellyfin-control.sh` | `/scripts/jellyfin-control.sh` |
| Arguments | `stop` | `start` |
| Fail on error | **yes** | **yes** |

- **Pre-backup with fail-on-error:** without a clean stop the SQLite database
  would be inconsistent — an inconsistent backup is worse than none.
- **Post-backup with fail-on-error:** the snapshot exists either way, but you
  want to see when Jellyfin does not come back at night.

Backup sources: `/var/lib/jellyfin` and `/etc/jellyfin`. Recommended exclude
pattern: `transcodes` (temporary transcode files). `cache` is a symlink to
`/var/cache/jellyfin` on a native install — restic stores only the symlink
itself, which is correct and keeps the backup small.

## Behavior & FAQ

- **Pre-hook exit 1 = the backup does not start.** That is deliberate: a file
  copy of the running `jellyfin.db` is a gamble (exclusive locks — the copy
  may be torn and refuse to restore); failing early with a clear cause is
  better than a snapshot that looks fine until the day you need it.
- **Failure compensation:** if the stop path fails after Jellyfin is already
  down (ACL error, verification failure, marker mismatch), the container
  script pushes a compensating start (best effort) before exiting 1 —
  Jellyfin never stays down overnight while the backup run aborts cleanly.
- **Timeouts:** `PREP_TIMEOUT` (default 600 s) — environment variable of the
  container script, in case your host needs longer;
  `TIMEOUT_STOP`/`TIMEOUT_START` (30/120 s) — environment variables of
  `jellyfin-service.sh` for the stop and HTTP-readiness wait loops.
- **Parallel runs:** if two backups start almost simultaneously, one may
  abort with `done marker does not match` — simply start it again (systemd
  serializes; the second trigger is queued).
- **The ACLs stay granted** (as with the Bitwarden prep): UID 33 keeps read
  access to the Jellyfin data. New 0600 files Jellyfin creates are outside
  the grant and only become readable with the next stop+grant — which runs
  before every backup, so the grant is always fresh exactly when restic
  needs it. Rollback is one command per tree:
  `sudo setfacl -R -x u:33 /var/lib/jellyfin`.
- **After stack updates:** the units live on the host and survive container
  recreations. Only when the scripts host path changes, adjust
  `@STACK_SCRIPTS@` in both unit files and run `systemctl daemon-reload`.
- **Restore:** write the snapshots back to the original paths, stop Jellyfin
  first, and its version must match the snapshot or be newer — Jellyfin has
  no downgrade path (database migrations run on first start and cannot be
  rolled back). A backup before every upgrade is the only way back.
- **Media:** the library is not part of this backup and is expected to be
  backed up separately. Playlists and collections reference the library
  paths — on the same server with unchanged media paths the restore is
  complete.
