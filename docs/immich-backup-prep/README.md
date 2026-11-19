# Preparing Immich backups — pre-backup prep script

This folder contains an event-coupled preparation step for MuckiFacilityPlugin
restic backups of a **Docker-based Immich installation** (the official Immich
compose stack with its Postgres database). Wire it into the backup
configuration of your `immich` repository and it runs **right before every
backup**, doing exactly two things on the Docker host:

1. **Fresh Postgres dump** — `docker exec -t immich_postgres pg_dump
   --clean --if-exists | gzip`, written to
   `<UPLOAD_LOCATION>/backups/immich-db-dump-manual-<ts>.sql.gz`. That is the
   same folder Immich's own automatic database backups use (Administration >
   Settings > Database Dump Settings) and the folder the restore UI reads —
   your manual dump is restore-ready next to Immich's nightly ones, and since
   it lives inside the upload tree it is automatically part of the backup.
2. **Read grants for the backup user** — `setfacl -R -m u:33:rX` on the
   Immich data paths (upload tree plus thumbs/encoded-video/profile when
   the `.env` points them to separate host directories). Every MuckiSafe
   backup process (Apache/PHP workers, scheduler messenger workers, restic)
   runs as `www-data` (UID 33), while the Immich stack writes its files
   (assets, nightly dumps) with its own ownership and restrictive modes.
   Without the grant, restic saves an **incomplete** snapshot and exits
   with code 3 (`at least one source file could not be read`).

**Why no stop, unlike the Jellyfin kit?** Jellyfin must be stopped for a
consistent file copy of its SQLite database. Immich runs on Postgres:
`pg_dump` takes a transactionally consistent (MVCC) snapshot while the
server keeps running. The official Immich documentation recommends, when not
stopping the server, to back up the **database first and the filesystem
second** — the worst case is files the database does not know about, which
can be re-uploaded after a restore. A pre-backup dump delivers exactly that
ordering, with zero downtime: no aborted ML/transcoding jobs, no failed
mobile uploads.

A cron job could dump on a clock, but the read grants decay the moment the
owning stack writes new 0600 files (Immich's nightly auto-dumps land in the
very folder you are backing up). This design couples the fresh dump and the
grant refresh to the backup event itself — both are guaranteed to exist
exactly when restic needs them.

## Why the detour through the host?

The pre-backup script runs **inside the MuckiSafe container as `www-data`**.
In the container there is no `docker` binary and no Docker socket (never mount
one), and `www-data` may neither `setfacl` on the Immich files nor
`docker exec` into the Postgres container. Instead, the container script drops
a marker file into the `scripts` bind mount (see `SCRIPTS_PATH` in
`docker-compose.override.yml`, mounted into both `app` and `scheduler` at
`/scripts`). A systemd **path unit** on the host watches that file and runs
the host-side script as root. No SSH, no keys, no Docker socket — just the
shared mount you already have.

The host script reads `UPLOAD_LOCATION`, `THUMB_LOCATION`,
`ENCODED_VIDEO_LOCATION`, `PROFILE_LOCATION`, `DB_USERNAME` and
`DB_DATABASE_NAME` directly from the Immich stack's `.env` on every run
(`IMMICH_ENV_FILE` in the service unit) — path changes in the Immich stack
flow into the next backup without touching the unit. It confirms its work
through the done marker, which also carries the result paths: the container
cannot know the host paths (it sees them only through the 1:1 bind mounts),
so it verifies exactly the paths the host reports.

```
┌─────────── MuckiSafe container (www-data) ───────────┐
│ immich-prep.sh                                         │
│   1. write /scripts/.immich/run (marker)               │
│   2. poll /scripts/.immich/done (max. PREP_TIMEOUT s)  │
│   3. verify dump + source paths readable as UID 33     │
│   exit 0 → backup starts                               │
└──────────────┬─────────────────────────────────────────┘
               │ shared SCRIPTS_PATH bind mount
┌──────────────▼────────────── Docker host (root) ──────┐
│ systemd path unit  →  muckisafe-immich-prep            │
│   docker exec -t immich_postgres pg_dump … | gzip      │
│     → <UPLOAD_LOCATION>/backups/…-manual-<ts>.sql.gz   │
│   setfacl -R -m u:33:rX  (upload tree + derivatives)   │
│   write done marker (marker, dump, source paths)       │
│   remove trigger                                       │
└────────────────────────────────────────────────────────┘
```

## Files

| File | Goes to |
|---|---|
| `immich-prep.sh` | `<scripts host dir>/immich-prep.sh` — container side, registered in the backup configuration (visible in the container as `/scripts/immich-prep.sh`) |
| `muckisafe-immich-prep` | `/usr/local/bin/muckisafe-immich-prep` — host side, runs as root |
| `muckisafe-immich-prep.path` | `/etc/systemd/system/` — watches the trigger file |
| `muckisafe-immich-prep.service` | `/etc/systemd/system/` — runs the host script |

## Installation (all on the Docker host)

```bash
# 0) Prerequisites
which setfacl || sudo apt-get install -y acl
docker ps --format '{{.Names}}' | grep immich   # → immich_postgres, immich_server, …

# 1) Determine the host path of the MuckiSafe scripts directory (STACK_SCRIPTS).
#    It is the source of the /scripts bind mount from docker-compose.override.yml:
docker inspect muckisafe-app --format '{{json .Mounts}}' | python3 -m json.tool | less
#    → look for Destination "/scripts" → Source, e.g. /srv/muckisafe/scripts

# 2) Determine the Immich compose directory (IMMICH_STACK_DIR, contains the .env):
docker inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'

# 3) Copy the files to their destinations (adjust paths!)
sudo cp muckisafe-immich-prep /usr/local/bin/
sudo cp muckisafe-immich-prep.path muckisafe-immich-prep.service /etc/systemd/system/
cp immich-prep.sh "$STACK_SCRIPTS/"

# 4) Replace BOTH placeholders in the unit files:
sudo sed -i "s|@STACK_SCRIPTS@|$STACK_SCRIPTS|g; s|@IMMICH_STACK_DIR@|$IMMICH_STACK_DIR|g" \
  /etc/systemd/system/muckisafe-immich-prep.{path,service}
# Sanity check: IMMICH_ENV_FILE in the .service must point to the real Immich .env.
# Different Postgres container name? → DB_CONTAINER=immich_postgres in the .service.

# 5) Permissions: the container user (UID 33) must be able to write into the
#    scripts directory; scripts themselves only need read+execute:
sudo chmod 755 /usr/local/bin/muckisafe-immich-prep "$STACK_SCRIPTS/immich-prep.sh"
sudo chown -R 33:33 "$STACK_SCRIPTS"

# 6) Activate the units:
sudo systemctl daemon-reload
sudo systemctl enable --now muckisafe-immich-prep.path
systemctl status muckisafe-immich-prep.path   # must show 'active (waiting)'
```

## Backup sources and bind mounts

restic runs inside the MuckiSafe containers — the Immich paths must be
mounted into **both** `app` and `scheduler` (`docker-compose.override.yml`),
using identical paths inside and outside so the restic snapshot paths match
the originals on restore. Take the values from the Immich stack `.env`:

```yaml
  app:
    volumes:
      - <UPLOAD_LOCATION>:<UPLOAD_LOCATION>:ro
      # only when the .env points them to paths OUTSIDE the upload tree:
      - <THUMB_LOCATION>:<THUMB_LOCATION>:ro
      - <ENCODED_VIDEO_LOCATION>:<ENCODED_VIDEO_LOCATION>:ro
      - <PROFILE_LOCATION>:<PROFILE_LOCATION>:ro
  scheduler:
    volumes:
      - ... # identical to app
```

What to register as backup sources:

| Path | Back up? | Why |
|---|---|---|
| `UPLOAD_LOCATION` | **yes** | original assets (`library/`), mobile upload queue (`upload/`), profile pictures — and `backups/` with **all database dumps**; one path covers everything |
| `THUMB_LOCATION` / `ENCODED_VIDEO_LOCATION` | recommended | regenerable (ML jobs), but without them a restore must re-render/re-transcode the whole library; exclude only when space is tight |
| `DB_DATA_LOCATION` | **no** | live database files of a running Postgres are inconsistent as a file copy — the restore path is the dump in `backups/` |
| `EXTERNAL_PATH` | **no** | external libraries are references: Immich stores no copy; the originals belong to the backup of their source location. After a restore, only the identical mount must exist again |

Apply mounts with `docker compose up -d` (a restart does not pick up new
mounts).

## Test (before wiring it into MuckiSafe)

Run the container script **as the backup user, not as root** — a root test
would be a false green:

```bash
cd <your muckisafe stack directory>
docker compose exec -u www-data app /scripts/immich-prep.sh
```

Expected output (duration: pg_dump + ACLs, seconds to a few minutes
depending on library size; the **first reaction can take up to ~30 s** —
systemd re-checks the path condition periodically in addition to inotify):

```
[immich-prep] Trigger gesetzt (1763...-123) — Host erzeugt jetzt frischen DB-Dump + Lese-ACLs (max. 600s warten)...
[immich-prep] Host-Arbeit erledigt.
[immich-prep] Verifikation OK:
[immich-prep]   DB-Dump: immich-db-dump-manual-20261119-031500.sql.gz
[immich-prep]   2 Quellpfad(e) für UID 33 lesbar
[immich-prep] Vorbereitung abgeschlossen — Backup kann starten.
```

Cross-check in the Immich web UI: **Administration > Maintenance > Restore
database backup** must list the new dump. Host-side log:
`journalctl -u muckisafe-immich-prep.service`

## Wiring into MuckiSafe

In the backup configuration of the `immich` repository, register the script
as the command to **run before the backup**, with fail-on-error enabled:

```
/scripts/immich-prep.sh
```

Then start the backup manually. The backup log must no longer contain
`permission denied`, and restic must finish with **exit 0**.

## Behavior & FAQ

- **Prep script exit 1 = do not start the backup.** That is deliberate:
  without a fresh dump and/or read grants the backup would be incomplete
  (restic exit 3) — failing early with a clear cause is better than a
  snapshot that looks fine until the day you need it.
- **Why into `backups/` and not a separate directory?** Immich writes its
  own automatic dumps there (default: daily at 02:00, keep last 14) and the
  restore UI reads exactly that folder. The manual pre-backup dump tightens
  the recovery point to the moment before restic runs; both variants are
  part of the file backup automatically, because the folder lives inside
  the upload tree.
- **Retention:** the host script keeps only its own last `DUMP_KEEP`
  (default 10) manual dumps — Immich's auto-backups are managed by Immich
  itself (Administration > Settings > Database Dump Settings).
- **Partial dumps never appear:** the dump is written to a `.part` file and
  renamed only after `pg_dump` and `gzip` succeeded, so the restore UI and
  the backup source never see a half-written file.
- **Timeouts:** `PREP_TIMEOUT` (container script, default 600 s) and
  `TimeoutStartSec` (systemd, 30 min) — raise both for very large
  libraries.
- **Parallel runs:** if two backups start almost simultaneously, one may
  abort with `done marker does not match` — simply start it again (systemd
  serializes; the second trigger is queued).
- **After stack updates:** the units live on the host and survive container
  recreations. The host script re-reads the Immich `.env` on every run, so
  path changes there flow in automatically. Only when the scripts host path
  or the Immich compose directory changes, adjust `@STACK_SCRIPTS@` /
  `@IMMICH_STACK_DIR@` in both unit files and run `systemctl daemon-reload`.
- **Why `setfacl` and not `chown`:** the upload tree belongs to the Immich
  stack — `chown -R 33:33` would break the running server. The ACL grant
  adds read access **only** for UID 33; Immich's processes access their
  files as the owner and never notice the entry. Rollback is one command
  per tree: `sudo setfacl -R -x u:33 <path>`.
- **Restore:** write the files (library/upload/…) back to their original
  paths first, then restore the database:
  - **web UI (recommended):** Administration > Maintenance > Restore
    database backup → pick the dump from `backups/` (it also automatically
    creates a restore point of the current database first).
  - **CLI (per the Immich docs):** start only `immich_postgres`, then
    `gunzip --stdout <dump>.sql.gz | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" | docker exec -i immich_postgres psql --dbname=<DB_DATABASE_NAME> --username=<DB_USERNAME> --single-transaction --set ON_ERROR_STOP=on`,
    afterwards `docker compose up -d`.
  - The Postgres image must match the running one (e.g.
    `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`) — the
    dump contains VectorChord/pgvector schema objects. Never restore into
    an Immich version older than the dump (no downgrade path); update Immich
    to the dump's version first if necessary.
  - With external libraries: make sure `${EXTERNAL_PATH}` is mounted
    identically again before the server starts.
- **What a complete Immich backup contains:** original assets, upload
  queue and profile pictures (`UPLOAD_LOCATION`), a fresh database dump
  (`backups/`), optionally thumbnails and encoded videos. The database dump
  carries all metadata — albums, users, permissions, face/CLIP indexes —
  without it the files are just a pile of data. A periodic restore test on
  a fresh installation is the only real completeness proof.
