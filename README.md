# MuckiSafe — Docker distribution

**MuckiSafe** packages [muckidrive](https://github.com/muckiware/muckidrive) — the
Shopware-6.7-core based application platform **without shop context** — together with
the Muckiware facility and logging plugins into a ready-to-run Docker image:

```
ghcr.io/muckiware/muckisafe:latest
```

What you get:

- **Administration UI** (Vue 3) of muckidrive, pre-built — no Node.js needed at runtime
- **MuckiFacilityPlugin** v0.7.0 — database backups, restic file backups, table cleanup
  (`muckiware:db:dump`, `muckiware:table:cleanup`, snapshot management)
- **MuckiLogPlugin** v2.4.0 — rotating log files, log levels, optional email alerts
- **MariaDB 11.8** and a **scheduled-task worker** for plugin background jobs
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
| `DB_PASSWORD`, `DB_ROOT_PASSWORD` | ✅ | MariaDB credentials |
| `MUWA_FACILITY_SECRET` | ✅ | Encryption key for backup repository passwords — **without it, encrypted repository passwords cannot be restored, ever** |
| `ADMIN_USERNAME`, `ADMIN_PASSWORD` | ✅ | Admin login, created on first boot |
| `ADMIN_EMAIL`, `SHOP_NAME`, `SHOP_EMAIL`, `SHOP_LOCALE`, `SHOP_CURRENCY` | – | Basic data for the initial installation |
| `MAILER_DSN` | – | SMTP for MuckiLogPlugin email alerts (default `null://null`) |
| `HTTP_PORT` | – | Host port for the admin UI (default `8080`) |

## Services

| Service | Purpose |
|---|---|
| `app` | Apache + PHP-FPM, serves the administration under `/admin` |
| `worker` | Runs `scheduled-task:run` every ~5 min: log mail dispatch, backup runs |
| `db` | MariaDB 11.8 with Shopware-compatible settings |

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
git clone https://github.com/muckiware/muckidrive.git
cd muckidrive
docker build -f docker/Dockerfile -t muckisafe:local .
docker run --rm -it -e DATABASE_URL=... muckisafe:local
```

The Dockerfile builds from the muckidrive repository — the plugins
(MuckiFacilityPlugin v0.7.0, MuckiLogPlugin v2.4.0) and the restic PHP library
(v1.5.0) are committed under `custom/` in that repository. One muckidrive-specific
patch is applied there: the MuckiLogPlugin storefront `ErrorControllerDecorator`
service definition is removed, because muckidrive does not load the Shopware
storefront bundle. See `docker/Dockerfile` for details.

## How the image is built & published

The GitHub workflow in this repository builds `ghcr.io/muckiware/muckisafe` from the
[muckidrive](https://github.com/muckiware/muckidrive) repository (multi-arch
`linux/amd64` + `linux/arm64`) on every push to `main` and on version tags `v*`.
Tag builds are additionally published as `ghcr.io/muckiware/muckisafe:vX.Y.Z`.

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
docker-compose.yml      End-user compose file (app + worker + db)
.env.example            All configurable variables with explanations
.github/workflows/      Image build & publish to GHCR
docs/                   Additional documentation
```

The application code itself lives in [muckiware/muckidrive](https://github.com/muckiware/muckidrive);
this repository only contains the Docker distribution layer.

## License

MIT — like muckidrive and the plugins.