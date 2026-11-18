# Preparing Bitwarden backups — pre-backup prep script

This folder contains an event-coupled preparation step for MuckiFacilityPlugin
restic backups of a **self-hosted Bitwarden server** (the official Bitwarden
Docker deployment with its `bwdata` tree, including the bundled MSSQL
database). Wire it into the backup configuration of your `bitwarden` repository
and it runs **right before every backup**, doing exactly two things on the
Docker host:

1. **Fresh MSSQL full backup** — `docker exec -i bitwarden-mssql /backup-db.sh`
   (the same job the server runs nightly, triggered on demand for a minimal
   recovery point). The resulting `.BAK` in `bwdata/mssql/backups/` is the
   restore path for the database.
2. **Read grants for the backup user** — `setfacl -R -m u:33:rX` on the
   Bitwarden data directory. Every MuckiSafe backup process (Apache/PHP
   workers, scheduler messenger workers, restic) runs as `www-data` (UID 33),
   while `bwdata` files belong to the Bitwarden stack (root / MSSQL UID 10001,
   modes 0600/0700). Without the grant, restic saves an **incomplete** snapshot
   and exits with code 3 (`at least one source file could not be read`) —
   missing precisely the restore-critical files: the `.BAK`, `env/`
   (database + certificate passwords), `core/aspnet-dataprotection/`,
   `identity/identity.pfx`.

A cron job can do the same on a clock, but grants decay the moment the owning
stack writes new 0600 files (a fresh `.BAK` every night). This design couples
the refresh to the backup event itself — the grant is guaranteed to exist
exactly when restic needs it.

## Why the detour through the host?

The pre-backup script runs **inside the MuckiSafe container as `www-data`**.
In the container there is no `docker` binary and no Docker socket (never mount
one), and `www-data` may neither `setfacl` on root/10001-owned files nor
`docker exec` into the Bitwarden stack. Instead, the container script drops a
marker file into the `scripts` bind mount (see `SCRIPTS_PATH` in
`docker-compose.override.yml`, mounted into both `app` and `scheduler` at
`/scripts`). A systemd **path unit** on the host watches that file and runs the
host-side script as root. No SSH, no keys, no Docker socket — just the shared
mount you already have.

```
┌─────────── MuckiSafe container (www-data) ───────────┐
│ bitwarden-prep.sh                                      │
│   1. write /scripts/.prep/run (marker)                │
│   2. poll /scripts/.prep/done (max. PREP_TIMEOUT s)    │
│   3. verify restore-critical files readable as UID 33  │
│   exit 0 → backup starts                               │
└──────────────┬─────────────────────────────────────────┘
               │ shared SCRIPTS_PATH bind mount
┌──────────────▼────────────── Docker host (root) ──────┐
│ systemd path unit  →  muckisafe-bitwarden-prep         │
│   docker exec -i bitwarden-mssql /backup-db.sh         │
│   setfacl -R -m u:33:rX /opt/bitwarden                 │
│   write done marker, remove trigger                    │
└────────────────────────────────────────────────────────┘
```

## Files

| File | Goes to |
|---|---|
| `bitwarden-prep.sh` | `<scripts host dir>/bitwarden-prep.sh` — container side, registered in the backup configuration (visible in the container as `/scripts/bitwarden-prep.sh`) |
| `muckisafe-bitwarden-prep` | `/usr/local/bin/muckisafe-bitwarden-prep` — host side, runs as root |
| `muckisafe-bitwarden-prep.path` | `/etc/systemd/system/` — watches the trigger file |
| `muckisafe-bitwarden-prep.service` | `/etc/systemd/system/` — runs the host script |

## Installation (all on the Docker host)

```bash
# 0) Prerequisites
which setfacl || sudo apt-get install -y acl
docker ps --format '{{.Names}}' | grep -i mssql   # container name (default: bitwarden-mssql)

# 1) Determine the host path of the scripts directory (STACK_SCRIPTS).
#    It is the source of the /scripts bind mount from docker-compose.override.yml:
docker inspect "$(docker compose ps -q app)" --format '{{json .Mounts}}' | python3 -m json.tool | less
#    → look for Destination "/scripts" → Source, e.g. /srv/muckisafe/scripts

# 2) Copy the files to their destinations (adjust paths!)
sudo cp muckisafe-bitwarden-prep /usr/local/bin/
sudo cp muckisafe-bitwarden-prep.path muckisafe-bitwarden-prep.service /etc/systemd/system/
cp bitwarden-prep.sh "$STACK_SCRIPTS/"

# 3) Replace the @STACK_SCRIPTS@ placeholder in BOTH unit files:
sudo sed -i "s|@STACK_SCRIPTS@|$STACK_SCRIPTS|g" \
  /etc/systemd/system/muckisafe-bitwarden-prep.{path,service}
# Different MSSQL container name?  → MSSQL_CONTAINER=bitwarden-mssql in the .service
# Bitwarden data not under /opt/bitwarden?  → BW_DATA_HOST=... in the .service

# 4) Permissions: the container user (UID 33) must be able to write into the
#    scripts directory; scripts themselves only need read+execute:
sudo chmod 755 /usr/local/bin/muckisafe-bitwarden-prep "$STACK_SCRIPTS/bitwarden-prep.sh"
sudo chown -R 33:33 "$STACK_SCRIPTS"

# 5) Activate the units:
sudo systemctl daemon-reload
sudo systemctl enable --now muckisafe-bitwarden-prep.path
systemctl status muckisafe-bitwarden-prep.path   # must show 'active (waiting)'
```

## Test (before wiring it into MuckiSafe)

Run the container script **as the backup user, not as root** — a root test
would be a false green:

```bash
cd <your muckisafe stack directory>
docker compose exec -u www-data app /scripts/bitwarden-prep.sh
```

Expected output (duration: DB backup + ACLs, seconds to a few minutes; the
**first reaction can take up to ~30 s** — systemd re-checks the path
condition periodically in addition to inotify):

```
[bitwarden-prep] Trigger set (1763...-123) — host is creating a fresh .BAK + read ACLs ...
[bitwarden-prep] Host work done.
[bitwarden-prep] Verification OK:
[bitwarden-prep]   .BAK: vault_FULL_20261118_104000.BAK
[bitwarden-prep]   env/global.override.env, identity.pfx, dataprotection: readable for UID 33
[bitwarden-prep] Preparation complete — the backup can start.
```

Host-side log: `journalctl -u muckisafe-bitwarden-prep.service`

## Wiring into MuckiSafe

In the backup configuration of the `bitwarden` repository, register the script
as the command to **run before the backup**:

```
/scripts/bitwarden-prep.sh
```

Then start the backup manually. The backup log must no longer contain
`permission denied`, and restic must finish with **exit 0**.

## Behavior & FAQ

- **Prep script exit 1 = do not start the backup.** That is deliberate:
  without a fresh `.BAK` and/or read grants the backup would be incomplete
  (restic exit 3) — failing early with a clear cause is better. If your
  backup configuration continues anyway, the restic log still shows the
  incomplete run.
- **Timeout:** `PREP_TIMEOUT` (default 600 s) — environment variable of the
  container script, in case your host needs longer (large databases).
- **Parallel runs:** if two backups start almost simultaneously, one may
  abort with `done marker does not match` — simply start it again (systemd
  serializes; the second trigger is queued).
- **After stack updates:** the units live on the host and survive container
  recreations. Only when the scripts host path changes, adjust
  `@STACK_SCRIPTS@` in both unit files and run `systemctl daemon-reload`.
- **Why `setfacl` and not `chown`:** the Bitwarden data tree belongs to the
  Bitwarden stack — `chown -R 33:33` would break the running server. The ACL
  grant adds read access **only** for UID 33 and never takes anything away
  from anyone; the Bitwarden processes access their files as the owner and
  never notice the entry. Rollback is one command:
  `sudo setfacl -R -x u:33 /opt/bitwarden`.
- **What a complete Bitwarden backup contains** (see
  [Backup Server Data](https://bitwarden.com/help/backup-on-premise/)): the
  entire `bwdata` tree; restore-critical pieces are `mssql/backups/*.BAK`
  (the database restore path — offline restore via sqlcmd preferred),
  `env/` (database + certificate passwords, no restore without them),
  `core/aspnet-dataprotection/` (auth tokens and some encrypted DB columns),
  `core/attachments/` (vault attachments are files and are **not** inside the
  `.BAK`), and `identity/identity.pfx`. Live `mssql/data/*.mdf` copied from a
  running server are inconsistent — restore runs through the `.BAK`. User
  master passwords are never part of any backup (zero-knowledge vault
  encryption); a periodic restore test on a fresh machine is the only real
  completeness proof.
