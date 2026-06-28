# atvloadly

IPA sideloading for Apple TV without Xcode, plus tooling to back up/restore the
pairing & Apple ID session and a host-side systemd service that refreshes the
apps on a schedule and pushes a notification with the result (success or failure).
Upstream: [bitxeno/atvloadly](https://github.com/bitxeno/atvloadly).

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [bitxeno/atvloadly](https://github.com/bitxeno/atvloadly) |
| **Image**    | `docker.io/bitxeno/atvloadly:latest`     |
| **Web UI**   | `http://<host>:5533`                     |
| **Storage**  | `/etc/atvloadly` (host bind) → `/data`   |
| **Network**  | default rootless network (publishes `5533:80`) |
| **Host deps**| `avahi-daemon`, host `dbus`, USB pairing (usbmuxd) |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
- **avahi** (this stack bind-mounts the host avahi/dbus sockets for device discovery):
  ```bash
  sudo apt install -y avahi-daemon
  sudo systemctl enable --now avahi-daemon
  ```
- **Rootless works here — verified, no rootful needed.** The host dbus
  (`/var/run/dbus/system_bus_socket`) and avahi (`/var/run/avahi-daemon/socket`)
  sockets are both mode `666` (world read-write) on a standard install — any
  rootless container can reach them with no extra config. The actual blockers
  were elsewhere — see Deploy and Notes.

## Deploy

```bash
cp atvloadly.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start atvloadly

# ONE-TIME, only if you're migrating existing data from the Docker stack:
# Docker ran as real root, so anything it wrote into /etc/atvloadly (besides
# files you created yourself) is root-owned. Rootless Podman's container
# identity is your real UID (via keep-id below), not real root, so it can't
# touch those leftovers until you reclaim them:
sudo chown -R "$(whoami):$(whoami)" /etc/atvloadly
```

State lives at the host path `/etc/atvloadly` (mounted as `/data`): pairing files,
Apple ID session, app database, settings — this is the backup target below.

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

## Verify

```bash
systemctl --user status atvloadly
podman logs atvloadly
curl -sI http://localhost:5533 | head -1
```

Web UI: `http://<host>:5533`.

## Backup

A clean backup excludes the heavy `.ipa` payloads and keeps only what's needed to
avoid re-pairing/re-login on a fresh install:

```bash
sudo tar -czf ~/atvloadly-backup-$(date +%Y-%m-%d)-clean.tar.gz \
  -C /etc/atvloadly \
  --exclude='ipa' --exclude='*.ipa' --exclude='tmp' --exclude='log' .
```

Keeps: `PlumeImpactor/` (pairing record, `accounts.json` session, `adi.pb` +
`keys/*/key.pem` Anisette identity, CoreADI/storeservicescore libs),
`lockdown/SystemConfiguration.plist`, `app.db`, `settings.json`, `config.yaml`.
Drops: `ipa/` payloads, stray `*.ipa`, `tmp/`, `log/`.

Copy it off the host:

```bash
scp <user>@<host>:~/atvloadly-backup-*-clean.tar.gz "C:\path\to\backups\"
```

### Restore

On a fresh host (or after wiping `/etc/atvloadly`):

```bash
podman stop atvloadly
sudo mv /etc/atvloadly /etc/atvloadly.bak-$(date +%s) 2>/dev/null || true
sudo mkdir -p /etc/atvloadly
sudo tar -xzf atvloadly-backup-YYYY-MM-DD-clean.tar.gz -C /etc/atvloadly
ls -la /etc/atvloadly   # expect: PlumeImpactor/ lockdown/ app.db settings.json config.yaml
podman start atvloadly
podman logs -f atvloadly
```

A successful restore shows `Restoring session for <your-apple-id>...` then device
registration and install — with no pairing/login prompt in between.

If the archive is **corrupted/truncated**, `tar` processes entries sequentially,
so you can still recover everything before the break:

```bash
tar -xzf backup.tar.gz -C /restore/dest \
  atvloadly/PlumeImpactor atvloadly/lockdown atvloadly/app.db \
  atvloadly/settings.json atvloadly/config.yaml
```

## Tooling

Helper scripts in [`scripts/`](scripts) for install + a self-contained host
refresh-and-notify service. These are host-side and unchanged from the Docker
setup (they talk to the WebUI/MCP API, not to any container runtime).

| File | Runs on | Purpose |
|---|---|---|
| `Install-AppleTVApp_v2.ps1` | Windows | scp a new IPA to the host and install it via the MCP API |
| `Refresh-AppleTVApp.ps1` | Windows | Force a refresh via MCP and notify with the real result |
| `atvloadly-refresh.sh` | host | Force-refresh enabled apps via MCP, wait for completion, push the `ok/failed` result |
| `atvloadly-refresh.service` | host (systemd) | oneshot unit that runs the refresh script |
| `atvloadly-refresh.timer` | host (systemd) | Triggers the refresh daily at 20:30 |

**Refresh from Windows:**
```powershell
& .\Refresh-AppleTVApp.ps1 -PiHost <host> -AppId 4   # one app, forced
& .\Refresh-AppleTVApp.ps1 -PiHost <host>            # all expired/near-expiry
```

**Scheduled refresh-and-notify on the host:**
```bash
cp scripts/atvloadly-refresh.sh ~/atvloadly-refresh.sh && chmod +x ~/atvloadly-refresh.sh
sudo cp scripts/atvloadly-refresh.service scripts/atvloadly-refresh.timer /etc/systemd/system/
# edit /etc/systemd/system/atvloadly-refresh.service first: set User= and the ExecStart path
sudo systemctl daemon-reload
sudo systemctl enable --now atvloadly-refresh.timer
```

## Notes

- **Security deviation (intentional):** runs `SeccompProfile=unconfined` and mounts
  host `dbus`/`avahi` sockets — required for USB/usbmuxd pairing. Do **not** add
  `NoNewPrivileges` / `DropCapability=ALL` here; it breaks pairing.
- **Rootless works fine here — verified, despite looking like the most likely
  candidate to need rootful.** Three real fixes were needed, none of them
  "switch to rootful":
  1. **`UserNS=keep-id` + `User=1000:1000`.** `/etc/atvloadly` is owned by your
     real host user, mode `700` (owner-only — verified live). Docker accessed
     it as real root (bypasses all permission checks); a rootless container's
     own identity must literally equal the host owner's UID to get in at all.
     This image has no `PUID`/`PGID` switching of its own (unlike
     jellyfin/qbittorrent), so without this it runs as an unmapped identity
     and hits "Permission denied" on every read/write — same class of bug as
     qBittorrent's original issue.
  2. **`AddCapability=NET_BIND_SERVICE`.** The app binds directly to port 80
     *inside* the container — invisible under Docker (real root can bind any
     port), fatal under non-root rootless: `failed to listen: listen tcp4
     0.0.0.0:80: bind: permission denied`, instant crash loop, regardless of
     which **host** port is published. Confirmed live by running the exact
     `podman run` command in the foreground to see the real stderr (systemd
     was just showing `status=1` with no detail, and `podman logs` lost the
     output as fast as it crash-looped).
  3. **A one-time `chown` of pre-existing data** (Deploy) — only needed if
     you're migrating data Docker already wrote, since some of it is
     root-owned (e.g. `PlumeImpactor/lib/arm64-v8a/*.so`,
     `DeveloperDiskImages/tvOS_DDI/*`). A fresh install with no existing data
     wouldn't hit this.
  - **dbus/avahi sockets needed no fix at all** — verified `mode 666` (world
    read-write) on this host, reachable from any rootless container with zero
    extra configuration. The thing that *looked* like the rootless blocker
    wasn't one.
- **Edit the systemd unit before enabling:** `atvloadly-refresh.service` ships
  with `User=YOUR_USER` / `/home/YOUR_USER/...` placeholders — set your real user
  and path first.
- **Turn off atvloadly's built-in Auto-Refresh** (Settings → Task → Enable off) so
  only this host timer drives refreshes. Change the time by editing the
  `OnCalendar=` line in `atvloadly-refresh.timer` and running `sudo systemctl daemon-reload`.
- **Container runs on `Europe/Amsterdam`** (`TZ` + `/etc/localtime` mount) so both
  the timer and any in-app schedule use local wall-clock time, not UTC.

---
_Tested on: `raspberrypi` (Pi 4B, Debian 13 Trixie, Podman 5.4.2), 2026-06-28 —
migrated live from Docker with existing data in place (no re-pairing). Came up
healthy, web server bound on `:80` internally, Avahi discovery started, and
the WebUI confirmed the existing paired Apple TV/apps intact with no
pairing/login prompt. Needed `UserNS=keep-id`+`User=1000:1000` (real UID match
for the `700`-mode data dir), `AddCapability=NET_BIND_SERVICE` (port 80 bind
inside the container), and a one-time `chown` of root-owned leftovers from
Docker — see Notes. dbus/avahi sockets needed zero extra config, contrary to
this stack's original "likely needs rootful" assumption._
