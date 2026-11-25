# MuckiSafe host agent — installation on the Docker host

The MuckiSafe host agent (`mucki-agent`) runs the declarative pre/post/finally
actions of a backup — stop a service, dump a database, make files readable —
directly on the Linux host that runs the MuckiSafe stack. The control plane is
MuckiSafeAgentPlugin inside the MuckiSafe image; the agent itself is a
separate, static Linux binary with a systemd unit.

- **No Go toolchain** is needed on the host or in the image: the agent ships
  as a prebuilt binary for `amd64` and `arm64` from the GitHub releases of
  [muckiware/MuckiSafeAgentPlugin](https://github.com/muckiware/MuckiSafeAgentPlugin).
- The agent only talks HTTP(S) to MuckiSafe and polls for jobs; it never
  accepts incoming connections.
- What it may touch on the host is defined **only** by its local policy
  (`/etc/mucki-agent/policy.yaml`). The control plane sends actions that
  reference aliases from this policy — never paths, commands or URLs.
- Supported: Linux with systemd (V1). macOS and Windows are not supported.

## Overview

| Path | Owner / mode | Content |
|---|---|---|
| `/usr/local/bin/mucki-agent` | `root:root` `0755` | agent binary |
| `/etc/mucki-agent/config.yaml` | `root:root` `0600` | server URL, key ID, intervals |
| `/etc/mucki-agent/secret` | `root:root` `0600` (or `0400`) | one-time secret, nothing else |
| `/etc/mucki-agent/policy.yaml` | `root:root` `0644` or stricter | local alias policy |
| `/var/lib/mucki-agent/state` | `root:root` `0700` | job journal |
| `/var/lib/mucki-agent/wakeup` | `root:33` `0770` | wakeup files from the containers |
| `/etc/systemd/system/mucki-agent.service` | `root:root` `0644` | systemd unit (do not edit, use drop-ins) |

The agent refuses to start (exit code 78, no restart loop) if the config, the
secret, the policy (or one of their parent directories) or the state
directory is a symlink, belongs to another user or is writable by group or
others.

## 1. Prepare the MuckiSafe stack

On the same host, before installing the agent (details in the main README,
section [Host agent](../../README.md#host-agent)):

1. Put `MUWA_AGENT_ENCRYPTION_KEYRING` into `.env`.
2. Create the global wakeup directory and (re)start the stack:

   ```bash
   sudo install -d -o root -g 33 -m 0770 /var/lib/mucki-agent/wakeup
   docker compose up -d
   ```

`app` and `scheduler` mount `/var/lib/mucki-agent/wakeup` (or
`MUCKI_AGENT_WAKEUP_PATH`) at `/var/run/mucki-agent/wakeup` and write
`<job-id>.ready` files there as `www-data` (GID 33). The agent watches the
directory and polls immediately when a file appears. Wakeups are only hints:
the regular poll (`pollInterval`, default 10 s) stays authoritative, so lost
or duplicate wakeups are harmless.

## 2. Download and verify a release

Agent releases have their own tags `agent-vX.Y.Z` (the plugin keeps `vX.Y.Z`)
on <https://github.com/muckiware/MuckiSafeAgentPlugin/releases>. Each release
contains `mucki-agent-X.Y.Z-linux.tar.gz` and its checksum
`mucki-agent-X.Y.Z-linux.tar.gz.sha256`. Download both, verify the checksum,
then unpack:

```bash
VERSION=X.Y.Z   # e.g. 1.0.0, without "agent-v"
BASE=https://github.com/muckiware/MuckiSafeAgentPlugin/releases/download/agent-v$VERSION
curl -fLO "$BASE/mucki-agent-$VERSION-linux.tar.gz"
curl -fLO "$BASE/mucki-agent-$VERSION-linux.tar.gz.sha256"
sha256sum --check --strict "mucki-agent-$VERSION-linux.tar.gz.sha256"
tar -xzf "mucki-agent-$VERSION-linux.tar.gz"
cd "mucki-agent-$VERSION"
```

Do not continue if `sha256sum` does not print `OK`. The directory contains
the binaries `mucki-agent-linux-amd64` and `mucki-agent-linux-arm64`,
`install.sh`, `uninstall.sh`, `systemd/mucki-agent.service`,
`config.example.yaml`, `policy.example.yaml` and `SHA256SUMS`; `install.sh`
checks the binary against `SHA256SUMS` a second time. The checksums come from
the same release: they detect damaged or incomplete downloads, not a
compromised release — download only from the official repository.

## 3. First installation run

```bash
sudo ./install.sh
```

`install.sh` is idempotent. On the first run it

- picks the binary for the host architecture, verifies it and installs it as
  `/usr/local/bin/mucki-agent`;
- creates `/etc/mucki-agent`, `/var/lib/mucki-agent/state` and the wakeup
  directory with the owners and modes listed above;
- checks that `www-data` has GID 33 in every running container that mounts
  the wakeup directory (pass `--container NAME` to name them explicitly, e.g.
  with a custom `MUCKI_AGENT_WAKEUP_PATH`);
- copies `config.example.yaml` to `/etc/mucki-agent/config.yaml` and creates
  an empty `/etc/mucki-agent/policy.yaml` — existing files are never
  overwritten;
- installs the systemd unit, but neither enables nor starts it while the
  configuration is incomplete.

It never creates the secret.

## 4. Provision the agent and store the secret

In the MuckiSafe administration open **Settings → Extensions → Mucki Agent**,
tab *Agents*, and click **Provision agent** (ACL role *provisioner*). Give the
host a name. The dialog shows the **key ID** and the **secret exactly once** —
the server keeps only an encrypted copy and can never show it again.

Store the secret without leaving it in the shell history — paste it, press
Enter and then Ctrl+D (clear the terminal afterwards, the pasted secret stays
visible in its scrollback):

```bash
sudo sh -c 'umask 077; cat > /etc/mucki-agent/secret'
sudo chown root:root /etc/mucki-agent/secret
sudo chmod 0600 /etc/mucki-agent/secret
```

The file must contain the secret only (one trailing newline is allowed).
A lost secret cannot be recovered: use **Rotate secret** in the
administration instead.

## 5. Configure

Edit `/etc/mucki-agent/config.yaml` (it stays `root:root`, `0600`):

```yaml
server:
  url: https://muckisafe.example.com   # scheme://host[:port] of MuckiSafe, no path
  allowInsecureHttp: false
  keyId: <key ID from the dialog>
  secretFile: /etc/mucki-agent/secret
  requestTimeout: 30s
agent:
  pollInterval: 10s
  heartbeatInterval: 10s
  leaseDuration: 30s
  maxConcurrency: 1
  wakeupDirectory: /var/lib/mucki-agent/wakeup
  stateDirectory: /var/lib/mucki-agent/state
  policyFile: /etc/mucki-agent/policy.yaml
```

Unknown keys are rejected. `wakeupDirectory` must be the host side of the
wakeup mount — with a custom `MUCKI_AGENT_WAKEUP_PATH` put that path here.

**HTTPS is the default.** A `https://` URL is verified against the system CA
store; there is no option to skip TLS verification. Put MuckiSafe behind a
TLS reverse proxy (main README, [Reverse proxy / HTTPS](../../README.md#reverse-proxy--https))
and use its public URL.

**Plain HTTP must be enabled explicitly** with an `http://` URL **and**
`allowInsecureHttp: true` — e.g. for `http://127.0.0.1:8080` on the same
host. Every request and response is signed (HMAC with the secret, replay
protected), so HTTP is protected against tampering, but it is **not
confidential**: anyone on the network path can read job definitions and
results. Use it only on the host itself or a trusted network.

Then write the policy. `policy.example.yaml` from the release shows all
sections (services, containers, commands, paths, destinations, principals,
checks, endpoints) for the reference cases Bitwarden, Jellyfin, Immich and
Paperless:

```bash
sudo install -o root -g root -m 0644 policy.example.yaml /etc/mucki-agent/policy.yaml
sudoedit /etc/mucki-agent/policy.yaml   # keep only what this host needs
```

Check configuration, secret file and policy before starting:

```bash
sudo /usr/local/bin/mucki-agent config validate --config /etc/mucki-agent/config.yaml
```

## 6. Start

Run the installer again; with a valid configuration it derives the writable
paths from the policy (drop-in `mucki-agent.service.d/10-destinations.conf`)
and starts the service:

```bash
sudo ./install.sh
systemctl status mucki-agent
journalctl -u mucki-agent -f
```

In the administration the agent changes from *Waiting for first contact* to
*Active* and reports its version and capabilities. Now actions and repository
hooks can use it.

## Operation

| Task | Command |
|---|---|
| Status / logs | `systemctl status mucki-agent`, `journalctl -u mucki-agent` |
| Policy changed (aliases only) | `sudo systemctl reload mucki-agent` — an invalid policy keeps the previous one |
| Path or destination added to or changed in the policy | `sudo ./install.sh` — rewrites the drop-in, the sandbox only allows listed paths |
| Secret rotated in the administration | store the new secret as in step 4, then `sudo systemctl restart mucki-agent` |
| Update | download and verify the new release (step 2), `sudo ./install.sh` in the new directory |
| Remove | `sudo ./uninstall.sh` — keeps config, secret, policy, journal and wakeup directory |
| Remove everything | `sudo ./uninstall.sh --purge` — refuses while the journal still holds jobs |

The unit runs the agent as root inside a hardened systemd sandbox
(`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, reduced
capabilities, `UMask=0077`): only the state directory and the paths of the
policy are writable. Exit code 78 means an unsafe/invalid installation or a
key the control plane no longer accepts (rotated or revoked); systemd does not
restart the agent in that case — fix the cause, then restart it. On stop the
agent claims no new jobs; a running job gets up to 60 seconds, is then
terminated, journalled and reported.

## Releases and updates

Plugin and agent are released independently:

- **Plugin** (`muckiware/mucki-safe-agent-plugin`, tags `vX.Y.Z`): every
  release, once the version is listed on Packagist, sends the
  `repository_dispatch` event `muckisafe-agent-plugin-release` (requires the
  `MUCKISAFE_DISPATCH_TOKEN` secret in the plugin repository) with the payload
  `{"package": "muckiware/mucki-safe-agent-plugin", "ref": "vX.Y.Z"}` to this
  repository. That builds a new MuckiSafe image with exactly this plugin
  version; update the stack with `docker compose pull && docker compose up -d`.
- **Agent** (tags `agent-vX.Y.Z`): a GitHub release with the tarball and its
  checksum only — neither Packagist nor the image contain it. Update hosts as
  described under *Operation*.
