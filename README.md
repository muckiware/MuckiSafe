# MuckiSafe — Docker distribution

MuckiSafe serves a complete Backup & Restore solution, running in a ready-to-run Docker image with an administration UI for to manage all you backups from everywhere in your local network. 
- An agent-service on the Docker host executes pre/post/finally actions of a backup (stop a service, dump a database, …) and can be installed on any Linux host.
- The backups will be created by the restic (https://restic.readthedocs.io) backup tool and are stored in a repository on the host
- The backups are encrypted by a password. 
- The repository can be on any local disk, network share or cloud storage. 
- A mirror function can be copied on a S3 storage, so you have a second copy of your backups. 
- Its included a scheduler setup for each back configuration for perform automatically backups or database dumps.
- Restore selected backup snapshots from the administration UI or by command line.
- User management with roles and permissions for the administration UI.


**MuckiSafe** packages [muckidrive](https://github.com/muckiware/muckidrive) — the
Shopware-6.7-core based application platform **without shop context** — together with
the Muckiware facility, logging and agent plugins into a ready-to-run Docker image:

```
ghcr.io/muckiware/muckisafe:latest
```

What you get:

- **Administration UI** (Vue 3) of muckidrive, pre-built at image build time
- **MuckiFacilityPlugin** — database backups, restic file backups, table cleanup
  (`muckiware:db:dump`, `muckiware:table:cleanup`, snapshot management)
- **MuckiFacilityMenuPlugin** — administration menu for the facility features
- **MuckiLogPlugin** — rotating log files, log levels, optional email alerts
- **MuckiSafeAgentPlugin** (`muckiware/mucki-safe-agent-plugin`) — control plane of
  the MuckiSafe host agent: provisioning, declarative actions, Facility backup hooks
  and job queue. The Go agent itself is released separately and runs on the host;
  the image contains neither the agent nor a Go toolchain.
- **Node.js 22** and **Composer 2.7.7** inside the container for console and build tasks
- **MySQL 8.4** and a **Supercronic scheduler** for Shopware background jobs
- Optional **SSH access** as `root`, secured exclusively with one or more public keys
- First-boot installation: system + plugins + admin user are created automatically from
  environment variables — no SQL dump, no manual `system:install`

Every release contains the newest mutually compatible releases of the four
plugins; the exact versions are listed in the
[release notes](https://github.com/muckiware/MuckiSafe/releases) and in
`/var/www/html/.muckisafe-versions` inside the container.

## Quick start

```bash
curl -O https://raw.githubusercontent.com/muckiware/MuckiSafe/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/muckiware/MuckiSafe/main/.env.example
cp .env.example .env         # fill in secrets (see below)
docker compose up -d
```

Then open **http://localhost:8080/admin** and log in with `ADMIN_USERNAME` /
`ADMIN_PASSWORD` from your `.env`.

> The first boot takes 1–3 minutes (database creation, system installation,
> plugin activation). Watch it with `docker compose logs -f app`.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `APP_URL` | ✅ | Public URL of the instance (e.g. `https://muckisafe.example.com`) |
| `APP_SECRET` | ✅ | `openssl rand -hex 32` |
| `INSTANCE_ID` | ✅ | Random ID, `openssl rand -base64 24 \| tr -d /+` |
| `DB_PASSWORD`, `DB_ROOT_PASSWORD` | ✅ | MySQL credentials |
| `MUWA_FACILITY_SECRET` | ✅ | Encryption key for backup repository passwords — **without it, encrypted repository passwords cannot be restored, ever** |
| `ADMIN_USERNAME`, `ADMIN_PASSWORD` | ✅ | Admin login, created on first boot |
| `ADMIN_EMAIL`, `PROJECT_NAME`, `PROJECT_EMAIL`, `PROJECT_LOCALE` | – | Basic data for the initial installation |
| `MESSENGER_CRON` | – | Cron expression for `messenger:consume` (default `*/5 * * * *`) |
| `SCHEDULED_TASK_CRON` | – | Cron expression for `scheduled-task:run` (default `*/5 * * * *`) |
| `SCHEDULER_TIMEZONE` | – | Timezone used by Supercronic (default `Europe/Berlin`) |
| `MAILER_DSN` | – | SMTP for MuckiLogPlugin email alerts (default `null://null`) |
| `HTTP_PORT` | – | Host port for the admin UI (default `8080`) |
| `SYMFONY_TRUSTED_PROXIES` | – | Behind a TLS proxy: proxy IPs/CIDRs whose X-Forwarded-* headers are trusted, e.g. `192.168.1.10,172.16.0.0/12` or `private_ranges` (default: empty = no trusted proxies, see [Reverse proxy / HTTPS](#reverse-proxy--https)) |
| `SYMFONY_TRUSTED_HEADERS` | – | X-Forwarded headers honored from trusted proxies (default: `x-forwarded-for,x-forwarded-host,x-forwarded-port,x-forwarded-proto`; must not be empty while `SYMFONY_TRUSTED_PROXIES` is set) |
| `MUCKISAFE_VERSION` | – | Image version to run, e.g. `v0.0.4` (default `latest` = most recent release) |
| `SSH_PUBLIC_KEYS` | – | SSH public key **content** — one bare key per line, no file paths; empty disables SSH (see [SSH access](#ssh-access)) |
| `SSH_PORT` | – | Host port for SSH (default `2222`) |
| `BACKUP_REPOS_PATH` | – | Host directory for backup repositories — only used together with the [override](#backup-repositories-on-the-host) from `docker-compose.override.yml` (default `./backup-repos`) |
| `MUWA_AGENT_ENCRYPTION_KEYRING` | – | Versioned keyring that encrypts the [host agent](#host-agent) secrets; required to provision agents — **keep it as safe as `MUWA_FACILITY_SECRET`** |
| `MUCKI_AGENT_WAKEUP_PATH` | – | Host directory for [host agent](#host-agent) wakeup files, mounted into `app` and `scheduler` (default `/var/lib/mucki-agent/wakeup`) |

## SSH access

SSH is opt-in and starts only when `SSH_PUBLIC_KEYS` is set. The base Compose
file does not publish port 22; `docker-compose.ssh.yml` adds the port only for
SSH-enabled deployments. Login is always `root`; password, keyboard-interactive
and empty-password authentication are disabled. Only public-key authentication
is accepted.

### What goes into `SSH_PUBLIC_KEYS`

The variable contains the **public key content itself — not a path to a key
file**. Each entry is one bare public-key line, exactly as printed by
`cat ~/.ssh/id_ed25519.pub` (key type, base64 key, optional comment):

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@workstation
```

- **One key per line** — multiple keys are separated by real newlines or a
  literal `\n` in a double-quoted `.env` value.
- **Allowed key types:** `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`,
  `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521` and the FIDO/hardware key types
  `sk-ssh-ed25519@openssh.com` and `sk-ecdsa-sha2-nistp256@openssh.com`.
- **Bare keys only:** `authorized_keys` options (`command="..."`, `no-pty`, …)
  are rejected — they could silently alter the intended access policy.
- **Validated at container start:** every line must pass `ssh-keygen -l -f`
  before it is written to `/root/.ssh/authorized_keys`. Passing a file path
  does not work — the path string is parsed as a key, fails validation, and
  stops the app container. Invalid input never results in a silently broken
  or unintended SSH configuration.
- **Empty value** (the default): SSH stays disabled.

For one key, first download the optional Compose override and configure `.env`:

```bash
curl -O https://raw.githubusercontent.com/muckiware/MuckiSafe/main/docker-compose.ssh.yml
```

```dotenv
SSH_PORT=2222
SSH_PUBLIC_KEYS=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... workstation
```

For multiple keys, put `\n` between complete public-key lines:

```dotenv
SSH_PUBLIC_KEYS="ssh-ed25519 AAAA... workstation\nssh-ed25519 AAAA... laptop"
```

Then recreate the app container and connect:

```bash
docker compose -f docker-compose.yml -f docker-compose.ssh.yml up -d --force-recreate app
ssh -p 2222 root@localhost
```

The server host keys live in the `ssh-host-keys` volume, so the SSH fingerprint
remains stable when the app container is recreated.

### Running `bin/console` over SSH

An SSH session does **not** inherit the container environment — `sshd` builds
the login environment from scratch, so `DATABASE_URL`, `APP_ENV` and
`MUCKIWARE_ROOT` are missing and every `bin/console` command fails with
`Doctrine\DBAL\Exception\ConnectionException (2002) Connection refused`
even though the admin UI works fine.

Console commands belong in one of two places:

1. From the host — `docker compose exec` injects the full container
   environment:

   ```bash
   docker compose exec app bin/console plugin:refresh
   ```

2. Inside the SSH session — load the runtime environment from PID 1 first:

   ```bash
   for VAR in DATABASE_URL APP_ENV APP_URL APP_SECRET INSTANCE_ID MUCKIWARE_ROOT COMPOSER_HOME MAILER_DSN; do
       VAL="$(tr "\0" "\n" < /proc/1/environ | grep "^${VAR}=" | cut -d= -f2-)"
       [ -n "$VAL" ] && export "$VAR=$VAL"
   done
   bin/console plugin:refresh
   ```

After any console command run as `root` (SSH session or `docker compose exec`),
restore file ownership so the web server keeps working:

```bash
docker compose exec app chown -R www-data:www-data var public
```

## Services

| Service | Purpose |
|---|---|
| `app` | Apache + PHP, serves `/admin`; optional key-only SSH on container port 22 |
| `scheduler` | Supercronic: runs `messenger:consume` and `scheduled-task:run` on configurable schedules |
| `db` | MySQL 8.4 with Shopware-compatible settings |

### Scheduler

By default, both standard Shopware commands run every five minutes:

```text
bin/console messenger:consume low_priority failed async --time-limit=60 --memory-limit=512M
bin/console scheduled-task:run --time-limit=120 --memory-limit=512M
```

Change the five-field cron expressions in `.env`, then recreate the scheduler:

```dotenv
MESSENGER_CRON=*/5 * * * *
SCHEDULED_TASK_CRON=*/5 * * * *
SCHEDULER_TIMEZONE=Europe/Berlin
```

```bash
docker compose up -d --force-recreate scheduler
docker compose logs -f scheduler
```

`flock` prevents a second copy of the same command from starting while the
previous invocation is still running.

## Backup repositories on the host

A backup repository of MuckiFacilityPlugin lives wherever its `repository_path`
points — a free local path inside the container. Without further configuration
that path is just a directory inside the container: the repository is lost
whenever the container is recreated, i.e. on every image update.

To create and write repositories **outside** the container — directly visible
and writable on the Docker host — bind-mount a host directory into both
services with a Compose override. Docker Compose merges a
`docker-compose.override.yml` next to `docker-compose.yml` automatically; the
base compose file stays untouched:

```yaml
services:
  app:
    volumes:
      - ${BACKUP_REPOS_PATH:-./backup-repos}:/var/backups/muckisafe

  scheduler:
    volumes:
      - ${BACKUP_REPOS_PATH:-./backup-repos}:/var/backups/muckisafe
```

**Both services need the mount.** Backups run in the `app` container (manual
runs from the administration) as well as in the `scheduler` container
(scheduled runs); a mount on only one of them leads to the error
`Repository path does not exist` on the other path.

Create the host directory before the next start (otherwise Docker creates it
owned by `root`), then recreate the stack:

```bash
mkdir -p backup-repos
docker compose up -d
```

In the administration, create the repository with a `repository_path` under
the mount, e.g. `/var/backups/muckisafe/shop-db` — restic creates the
repository directory itself, the mount point must exist. Everything restic
writes lands live in `./backup-repos` on the host, so you can sync it to
another disk, or inspect it with a locally installed restic:

```bash
restic -r backup-repos/shop-db snapshots
```

Notes:

- **Linux hosts:** backups run as `www-data` (UID 33). The host directory must
  be writable by that UID — `sudo chown -R 33:33 ./backup-repos`. Docker
  Desktop on macOS/Windows maps container writes to your host user
  automatically, so no `chown` is needed there.
- `BACKUP_REPOS_PATH` in `.env` redirects the mount (default `./backup-repos`).
  When you change it, move the existing repository directories along —
  otherwise the plugin reports `Repository path does not exist`.
- The override merges automatically only when you run `docker compose` without
  explicit `-f` files. The SSH stack from [SSH access](#ssh-access) uses `-f`;
  include the override there explicitly:

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.ssh.yml -f docker-compose.override.yml up -d
  ```

## Backing up external databases

MuckiFacilityPlugin can dump not only MuckiSafe's own MySQL database but any
external MySQL or MariaDB server reachable from the container — e.g. the
MariaDB of another Compose stack on the same Docker host. Dumps run through
`mysqldump` (Debian bookworm's `mariadb-client`, part of the image since the
runtime stage installs it), which covers both server flavours: a MariaDB
10.11 client dumps MariaDB (all current versions) and MySQL 8.x, including
users with `caching_sha2_password`.

For a database that lives in another Compose stack (typically without a
published host port), wire it up in three steps:

1. **Shared Docker network** — create it once on the host:

   ```bash
   docker network create backup-net
   ```

   Attach it on both sides. The database side gets a unique alias — never use
   the service name `db`: both stacks alias their database `db`, and once a
   container is on two networks that name resolves non-deterministically.

   ```yaml
   # in the OTHER stack's docker-compose.yml:
   services:
     db:
       networks:
         default: null
         backup-net:
           aliases:
             - paperless-db   # unique alias, used as host in MuckiSafe

   networks:
     backup-net:
       name: backup-net
       external: true
   ```

   In MuckiSafe, extend the override from
   [Backup repositories on the host](#backup-repositories-on-the-host) with the
   same network — and keep `default` listed:

   ```yaml
   # in docker-compose.override.yml of MuckiSafe:
   services:
     app:
       networks:
         - default        # keep! otherwise the service loses its own network
         - backup-net

     scheduler:
       networks:
         - default
         - backup-net

   networks:
     backup-net:
       name: backup-net
       external: true
   ```

   **`default` must stay listed.** As soon as a service declares `networks:`,
   the implicit default network is dropped and `DATABASE_URL` (host `db`)
   stops resolving. Both services need the new network: the connection test
   runs in `app`, the dump itself runs in the `scheduler` messenger worker.

2. **Dedicated dump user** in the external database — minimal grants, so the
   application credentials never have to be stored in MuckiSafe:

   ```sql
   CREATE USER 'muckisafe_backup'@'%' IDENTIFIED BY '<password>';
   GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER, EVENT ON <database>.* TO 'muckisafe_backup'@'%';
   GRANT PROCESS ON *.* TO 'muckisafe_backup'@'%';
   ```

   `mysqldump --single-transaction` (set by the plugin) needs nothing beyond
   that. A `%` host is fine as long as the database has no published host
   port — the user is then only reachable from the Docker networks.

3. **Database connection in the administration**: type `mysql`, host = the
   alias from step 1 (e.g. `paperless-db`), port 3306, database name, and the
   dump user with its password (stored encrypted via `MUWA_FACILITY_SECRET`).
   Test the connection, then assign it to a backup repository with a database
   backup type.

## Host agent

MuckiSafeAgentPlugin (`muckiware/mucki-safe-agent-plugin`) is the control
plane of the MuckiSafe host agent: a separate Linux binary with systemd unit,
released on its own, that runs the declarative pre/post/finally actions of a
backup (stop a service, dump a database, …) on the Docker host. The image
contains neither the agent nor a Go toolchain. Two settings connect the stack
to it; without them everything else works unchanged.

**Installing the agent on the host** — download of the `agent-vX.Y.Z` GitHub
release with SHA-256 check, `install.sh`, systemd, root-owned
config/secret/state, HTTPS by default and explicit HTTP, updates and removal:
see [docs/host-agent/README.md](docs/host-agent/README.md). Neither Go nor a
build step is needed on the host.

**Encryption keyring.** Agent secrets are stored encrypted with
`MUWA_AGENT_ENCRYPTION_KEYRING`, which `app` and `scheduler` both receive
unchanged. Generate a keyring with one key and put the printed line into `.env`
(the single quotes are required):

```bash
printf "MUWA_AGENT_ENCRYPTION_KEYRING='{\"active\":1,\"keys\":{\"1\":\"%s\"}}'\n" "$(openssl rand -hex 32)"
docker compose up -d
```

Every key is 64 hex characters (32 bytes). Without the keyring, provisioning
an agent in the administration fails with *keyring missing or invalid*. A lost
keyring makes all stored agent secrets unreadable: revoke the agents and
provision them again with a new keyring.

To change the key, add a new version and make it active
(`{"active":2,"keys":{"1":"…","2":"…"}}`) and recreate the stack. Then
re-encrypt the secrets stored under the old version with
`POST /api/_action/muwa/agent/master-key/reencrypt` and the body
`{"fromVersion":1}` (optional `"batchSize"`, 1–1000, default 100; ACL
`muwa_agent.master_key_reencrypt`). The route works in batches: **repeat it
until the response contains `"removalAllowed": true`** — only then remove
version 1 from the keyring. Removing it earlier makes the remaining agent
secrets unreadable.

**Wakeup directory.** Right after it queues a job, the plugin drops a
`<job-id>.ready` file into `/var/run/mucki-agent/wakeup`, so the agent claims
the job immediately instead of at its next poll. Both `app` (backups started in
the administration) and `scheduler` (scheduled backups) bind-mount the same
host directory `MUCKI_AGENT_WAKEUP_PATH` (default
`/var/lib/mucki-agent/wakeup`) there and write as `www-data` (UID/GID 33).
Create it on the Linux host **before** starting the stack — Compose does not
set owner or mode, and a directory Docker creates on its own belongs to
`root:root`, so the containers could not write to it:

```bash
sudo install -d -o root -g 33 -m 0770 /var/lib/mucki-agent/wakeup
docker compose up -d
```

The command is idempotent and also repairs owner and mode of an existing
directory; the agent's `install.sh` runs the same step for the default path
(with a custom path, pass the containers via `install.sh --container NAME` so
it can check their `www-data` GID). Verify that both
services can write:

```bash
docker compose exec -u www-data app touch /var/run/mucki-agent/wakeup/probe && \
docker compose exec scheduler rm /var/run/mucki-agent/wakeup/probe && echo writable
```

Wakeups are only hints: polling stays authoritative, so a missing or
read-only directory delays jobs until the next poll but loses none, and the
plugin logs a warning. With a custom `MUCKI_AGENT_WAKEUP_PATH` use that path in
the `install -d` command and as `wakeupDirectory` in the agent configuration.
The agent runs on Linux only; on Docker Desktop (macOS/Windows) the default
path is created inside the Docker VM, which is harmless.

## Upgrades

The container checks nothing automatically. To upgrade:

```bash
docker compose pull
docker compose up -d
```

What happens on boot (`docker/entrypoint.sh`):

1. **New image?** The image carries a fingerprint of its resolved `composer.lock`
   (`.image-fingerprint`); the fingerprint applied last is stored in the `var`
   volume. If they differ, the cache of the previous image is dropped.
2. **Fresh database?** Decided by looking at the database itself
   (`docker/db-probe.php`): only a database without tables is installed with
   `system:install`. A console command failing for any other reason never
   triggers a reinstall over existing data.
3. **Admin user** is created whenever no user exists yet.
4. **Migrations** — for every new image `system:update:finish` runs, so
   migrations of `muckiware/core` and `muckiware/master` are applied even when
   the Shopware core version did not change.
5. **Plugins** — `vendor/bin/shopware-deployment-helper run` installs plugins
   added in a newer image, updates outdated ones, activates inactive ones and
   runs `scheduled-task:register`.

The scheduler only runs its jobs while its own image fingerprint matches the
applied one, so a scheduler of the previous image idles during an update.

Plugin and platform updates arrive via new image versions. `latest` always
points to the most recent release; to stay on a specific release, set
`MUCKISAFE_VERSION` (e.g. `MUCKISAFE_VERSION=v0.0.4`) in `.env`.

### Persistent data

| Volume | Path | Content |
|---|---|---|
| `app-var` | `var/` | logs, cache, database dumps (`var/db/backup`) |
| `app-files` | `files/` | private filesystem, uploads of the facility plugin |
| `app-media` | `public/media/` | media files |
| `db-data` | MySQL | database |
| `ssh-host-keys` | `/var/lib/muckisafe-ssh` | SSH host keys |

Everything else inside the container comes from the image and is replaced on
every update. `app-files` and `app-media` were added later: when updating an
older deployment, download the current `docker-compose.yml` first.

Backup repositories are not part of these volumes by default — a repository
created in the administration lives inside the container and is lost on every
image update, unless you add the bind mount from
[Backup repositories on the host](#backup-repositories-on-the-host).

## Building the image yourself

```bash
git clone https://github.com/muckiware/MuckiSafe.git
cd MuckiSafe
git clone https://github.com/muckiware/muckidrive.git muckidrive
docker build -f docker/Dockerfile -t muckisafe:local .
```

The build context is the MuckiSafe repository with the muckidrive platform cloned
into `./muckidrive` (the CI workflow does exactly this). The Dockerfile copies
the platform skeleton from `muckidrive/`, then adds the Muckiware plugins at
build time via one `composer require` from Packagist (MuckiFacilityPlugin,
MuckiFacilityMenuPlugin, MuckiLogPlugin, MuckiSafeAgentPlugin). Their versions
are composer constraints passed as build args (`FACILITY_PLUGIN_VERSION`,
`FACILITY_MENU_PLUGIN_VERSION`, `LOG_PLUGIN_VERSION`, `AGENT_PLUGIN_VERSION`);
the default `*` makes composer pick the newest stable release of each plugin
that is compatible with the others. Pass e.g.
`--build-arg FACILITY_PLUGIN_VERSION=0.9.0` to pin one. Local plugin checkouts
inside the muckidrive clone are removed before, so they never shadow Packagist.
The restic PHP client library comes from Packagist as a dependency of
MuckiFacilityPlugin. The resolved versions are written to
`/var/www/html/.muckisafe-versions`. The restic binary itself comes from the official restic
GitHub release, not from Debian (bookworm only ships 0.14.0, which is too old
for the plugin): the version is the build arg `RESTIC_VERSION` (default 0.18.1)
together with `RESTIC_SHA256_AMD64` / `RESTIC_SHA256_ARM64`, which must match
the release's `SHA256SUMS`. The plugins are
installed, activated and updated on every container start by
[shopware/deployment-helper](https://github.com/shopware/deployment-helper)
(`vendor/bin/shopware-deployment-helper run`, called from `docker/entrypoint.sh`).
The administration is built with `CI=1`, so `bin/ci` loads all composer-installed
plugins and their administration modules and assets become part of the image.
One muckidrive-specific patch is applied during the build for MuckiLogPlugin up
to v2.4.0: the storefront `ErrorControllerDecorator` service definition is
removed, because muckidrive does not load the Shopware storefront bundle (from
v2.5.0 on the plugin ships it disabled). See `docker/Dockerfile` for details.

## How the image is built & published

The GitHub workflow in this repository checks out MuckiSafe, clones the
[muckidrive](https://github.com/muckiware/muckidrive) platform into `./muckidrive`
and builds `ghcr.io/muckiware/muckisafe` (multi-arch `linux/amd64` +
`linux/arm64`).

### Releases and versions

One release is one version number and one image tag. Every release publishes
exactly two image tags — its version (`vX.Y.Z`) and `latest` — and creates the
matching Git tag and GitHub release. The release notes list the muckidrive and
plugin versions inside the image.

| Trigger | Result |
|---|---|
| Git tag `vX.Y.Z` pushed manually (changes to MuckiSafe itself) | release `vX.Y.Z` |
| Release of muckidrive, core, master, MuckiLogPlugin, MuckiFacilityPlugin, MuckiFacilityMenuPlugin or MuckiSafeAgentPlugin | next patch release, created automatically |
| *Run workflow* on `main` (optional `muckidrive_ref` input) | next patch release |
| Push to `main`, pull request | test build (`linux/amd64`), nothing is published |

Every build uses the latest release tag of muckidrive; only an explicit
`muckidrive_ref` (platform release event or manual input) overrides it.
`muckiware/core`, `muckiware/master` and the four plugins are resolved by
composer at build time (muckidrive does not commit a `composer.lock`): each
plugin gets its newest stable release that is compatible with the others. A
plugin release pins only that plugin to the released version, so the build
fails visibly if a sibling plugin does not accept it yet (release a compatible
version of the sibling, then re-run the failed build). A plugin release event
whose payload names another package than the event's plugin, or whose `ref` is
not a release version `vX.Y.Z`, fails the build before anything is built
(`.github/scripts/resolve-plugin-versions.sh`).

### Release events

The component repositories start a release with a `repository_dispatch` event:

| Repository | Event type | Payload |
|---|---|---|
| [muckiware/muckidrive](https://github.com/muckiware/muckidrive) | `muckidrive-release` | `muckidrive_ref` |
| [muckiware/core](https://github.com/muckiware/core) | `muckidrive-core-release` | `package`, `ref` |
| [muckiware/master](https://github.com/muckiware/master) | `muckidrive-master-release` | `package`, `ref` |
| [muckiware/MuckiLogPlugin](https://github.com/muckiware/MuckiLogPlugin) | `muckilog-plugin-release` | `package`, `ref` |
| [muckiware/MuckiFacilityPlugin](https://github.com/muckiware/MuckiFacilityPlugin) | `muckifacility-plugin-release` | `package`, `ref` |
| [muckiware/MuckiFacilityMenuPlugin](https://github.com/muckiware/MuckiFacilityMenuPlugin) | `muckifacility-menu-plugin-release` | `package`, `ref` |
| [muckiware/MuckiSafeAgentPlugin](https://github.com/muckiware/MuckiSafeAgentPlugin) | `muckisafe-agent-plugin-release` | `package` (`muckiware/mucki-safe-agent-plugin`), `ref` |

Releases are queued, so components released together do not build in parallel
or receive the same version number; when several are waiting, only the newest
one runs — it contains all of them. Every image carries the labels
`io.muckiware.muckidrive.ref`, `io.muckiware.trigger` and
`io.muckiware.trigger.ref`; the plugin versions composer resolved are listed in
`/var/www/html/.muckisafe-versions` inside the image and in the release notes.

All triggers require the `MUCKISAFE_DISPATCH_TOKEN` secret (a fine-grained PAT
with *contents: write* on this repository) on the triggering repository; until
it is configured, the release workflow there skips the trigger with a warning.

## Reverse proxy / HTTPS

The compose file publishes plain HTTP on `HTTP_PORT`. Put your own reverse proxy
(Caddy, Traefik, nginx) in front for TLS. Example Caddyfile:

```
muckisafe.example.com {
    redir / /admin 302
    reverse_proxy localhost:8080
}
```

The `redir` line is optional: the application has no storefront, so the root
path returns 404 — this sends visitors of `https://…/` conveniently to `/admin`.
The `/admin` path itself passes through the proxy unchanged and all admin API
calls use the same host, so no path rewriting is needed (or wanted).

Set `APP_URL` to the public `https://` URL — the application generates absolute
links (admin assets, emails) from it.

### Trusted proxies (required behind TLS)

The admin UI builds absolute asset URLs from the request the PHP application
sees. A TLS proxy terminates HTTPS and forwards plain HTTP, so without further
configuration the application answers with `http://…` asset links on an
`https://` page — the browser blocks them as mixed content and the admin UI
fails to load.

The proxy must announce the original request (`X-Forwarded-Proto: https` —
Caddy, Traefik and nginx send it by default), and the application must be told
to believe it, via `SYMFONY_TRUSTED_PROXIES` in `.env`:

```dotenv
# reverse proxy on 192.168.1.10, plus the Docker bridge networks of the host
SYMFONY_TRUSTED_PROXIES=192.168.1.10,172.16.0.0/12
# or, conveniently for home networks: trust all private subnets
#SYMFONY_TRUSTED_PROXIES=private_ranges
```

- `docker-compose.yml` forwards `SYMFONY_TRUSTED_HEADERS` with a safe default
  (`x-forwarded-for,x-forwarded-host,x-forwarded-port,x-forwarded-proto`);
  set it only to change that list.
- **Never set proxies without a header list**: an empty `SYMFONY_TRUSTED_HEADERS`
  together with a non-empty `SYMFONY_TRUSTED_PROXIES` aborts the kernel boot
  (`The trusted header "" is not supported.`). Leave both empty when nothing
  proxies the stack.
- Only the listed sources' X-Forwarded-* headers are trusted; direct requests
  from other clients are unaffected.
- Apply changes with `docker compose up -d` (the entrypoint clears the Symfony
  cache on every boot) and hard-reload the browser afterwards — the old HTML
  with `http://` asset links may still be cached.

## Repository layout

```
docker-compose.yml      End-user compose file (app + scheduler + db)
docker-compose.ssh.yml  Optional SSH host-port override
.env.example            All configurable variables with explanations
docker/Dockerfile       Image build: muckidrive platform + Muckiware plugins
docker/entrypoint.sh    First-boot installation, image updates, plugins + Apache start
docker/db-probe.php     Database inspection for the entrypoint (no kernel boot)
.dockerignore           Build context filter
.github/workflows/      Image build & publish to GHCR
docs/host-agent/        Installation of the separate MuckiSafe host agent on the Docker host
```

The application code itself lives in [muckiware/muckidrive](https://github.com/muckiware/muckidrive)
(the base platform, Docker-free) — this repository contains everything Docker:
build recipe, distribution and documentation.

## License

MIT — like muckidrive and the plugins.