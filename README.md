# MuckiSafe — Docker distribution

**MuckiSafe** packages [muckidrive](https://github.com/muckiware/muckidrive) — the
Shopware-6.7-core based application platform **without shop context** — together with
the Muckiware facility and logging plugins into a ready-to-run Docker image:

```
ghcr.io/muckiware/muckisafe:latest
```

What you get:

- **Administration UI** (Vue 3) of muckidrive, pre-built at image build time
- **MuckiFacilityPlugin** v0.8.0 — database backups, restic file backups, table cleanup
  (`muckiware:db:dump`, `muckiware:table:cleanup`, snapshot management)
- **MuckiLogPlugin** v2.4.0 — rotating log files, log levels, optional email alerts
- **Node.js 22** and **Composer 2.7.7** inside the container for console and build tasks
- **MySQL 8.4** and a **Supercronic scheduler** for Shopware background jobs
- Optional **SSH access** as `root`, secured exclusively with one or more public keys
- First-boot installation: system + plugins + admin user are created automatically from
  environment variables — no SQL dump, no manual `system:install`

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
| `SSH_PUBLIC_KEYS` | – | SSH public key **content** — one bare key per line, no file paths; empty disables SSH (see [SSH access](#ssh-access)) |
| `SSH_PORT` | – | Host port for SSH (default `2222`) |

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

## Upgrades

The container checks nothing automatically. To upgrade:

```bash
docker compose pull
docker compose up -d
```

On boot the entrypoint runs `system:is-installed`; existing installations are left
untouched. Plugin updates arrive via new image versions.

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
build time — cloned from their public GitHub tags (MuckiFacilityPlugin v0.8.0,
MuckiLogPlugin v2.4.0, restic PHP client v1.5.0). One muckidrive-specific patch
is applied during the build: the MuckiLogPlugin storefront
`ErrorControllerDecorator` service definition is removed, because muckidrive
does not load the Shopware storefront bundle. See `docker/Dockerfile` for details.

## How the image is built & published

The GitHub workflow in this repository checks out MuckiSafe, clones the
[muckidrive](https://github.com/muckiware/muckidrive) platform into `./muckidrive`
and builds `ghcr.io/muckiware/muckisafe` (multi-arch `linux/amd64` +
`linux/arm64`) on every push to `main`, on version tags `v*` and weekly
(to pick up platform updates). Builds from `main` are published as `edge`, a
monotonically increasing `build-N` tag and a commit-specific `sha-...` tag.
SemVer tag builds such as `v0.0.2` additionally publish `v0.0.2`, the moving
patch-series tag `v0.0`, and `latest`; therefore `latest` always denotes the
most recent stable release. A manual build with a specific platform version is
possible via *Run workflow* (`muckidrive_ref` input) and receives `build-N` and
`sha-...` tags as well.

A muckidrive platform release (`v*` tag) triggers this workflow automatically
via a `repository_dispatch` event (`muckidrive-release`) with `muckidrive_ref`
pinned to that platform tag, so every release build is traceable to a tagged
platform version.

Releases of the platform packages trigger it as well:
[muckiware/core](https://github.com/muckiware/core) sends
`muckidrive-core-release` and [muckiware/master](https://github.com/muckiware/master)
sends `muckidrive-master-release` (payload `package` + `ref`). These builds use
the latest muckidrive release tag as platform source; composer resolves the new
package version at build time (muckidrive does not commit a `composer.lock`).
Builds are queued, so a joint core + master release does not run two builds in
parallel. Every image carries the labels `io.muckiware.muckidrive.ref`,
`io.muckiware.trigger` and `io.muckiware.trigger.ref`.

All three triggers require the `MUCKISAFE_DISPATCH_TOKEN` secret (a
fine-grained PAT with *contents: write* on this repository) on the triggering
repository (muckidrive, core, master); until it is configured, the release
workflow there skips the trigger with a warning.

## Reverse proxy / HTTPS

The compose file publishes plain HTTP on `HTTP_PORT`. Put your own reverse proxy
(Caddy, Traefik, nginx) in front for TLS. Example Caddyfile:

```
muckisafe.example.com {
    reverse_proxy localhost:8080
}
```

## Repository layout

```
docker-compose.yml      End-user compose file (app + scheduler + db)
docker-compose.ssh.yml  Optional SSH host-port override
.env.example            All configurable variables with explanations
docker/Dockerfile       Image build: muckidrive platform + Muckiware plugins
docker/entrypoint.sh    First-boot installation + Apache start
.dockerignore           Build context filter
.github/workflows/      Image build & publish to GHCR
```

The application code itself lives in [muckiware/muckidrive](https://github.com/muckiware/muckidrive)
(the base platform, Docker-free) — this repository contains everything Docker:
build recipe, distribution and documentation.

## License

MIT — like muckidrive and the plugins.