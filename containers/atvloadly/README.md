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
- **Rootless access to the host sockets + USB.** See the Notes — this is the most
  likely container to need **rootful Podman** (`sudo podman`) because device
  pairing (usbmuxd) and the host dbus/avahi sockets are awkward to reach from a
  rootless user namespace.

## Deploy

> ⚠️ UNTESTED on the host — verify before trusting (and see the rootless caveat above).

```bash
cp atvloadly.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start atvloadly
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
- **Rootless caveat (Podman-specific, the big one).** USB device pairing via
  usbmuxd and the host dbus/avahi sockets are easy under Docker (root daemon) but
  awkward rootless: the host sockets are root/group-owned and a rootless user
  namespace may not reach them, and USB access needs the device readable by your
  user. If pairing fails rootless, run this **one** stack rootful instead — put
  `atvloadly.container` in `/etc/containers/systemd/` and manage it with
  `sudo systemctl` (system Quadlet), or test socket/group permissions first.
  ⚠️ UNTESTED either way.
- **`/etc/atvloadly` is root-owned.** Rootless Podman writes into it as your
  mapped user; if you hit permission errors on `/data`, that ownership is why
  (another reason this stack may want rootful). The backup/restore commands use
  `sudo` for exactly this reason.
- **Edit the systemd unit before enabling:** `atvloadly-refresh.service` ships
  with `User=YOUR_USER` / `/home/YOUR_USER/...` placeholders — set your real user
  and path first.
- **Turn off atvloadly's built-in Auto-Refresh** (Settings → Task → Enable off) so
  only this host timer drives refreshes. Change the time by editing the
  `OnCalendar=` line in `atvloadly-refresh.timer` and running `sudo systemctl daemon-reload`.
- **Container runs on `Europe/Amsterdam`** (`TZ` + `/etc/localtime` mount) so both
  the timer and any in-app schedule use local wall-clock time, not UTC.

---
_⚠️ UNTESTED on this host — Quadlet translation of the tested Docker stack
([docker repo](https://github.com/hshamsaldin/docker/tree/main/containers/atvloadly)).
The Docker deploy/backup/restore are verified from the working setup documented in
[hshamsaldin/atvloadly](https://github.com/hshamsaldin/atvloadly); the rootless
Podman path (esp. USB/dbus/avahi) needs host verification._
