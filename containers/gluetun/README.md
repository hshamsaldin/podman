# gluetun (shared VPN pod)

ProtonVPN WireGuard tunnel that other containers ride for VPN-routed traffic.
Standalone infrastructure, not tied to any one app — qBittorrent rides it
today; connect future containers the same way (see Notes).

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [qdm12/gluetun](https://github.com/qdm12/gluetun) |
| **Image**    | `docker.io/qmcgaw/gluetun:latest`        |
| **Web UI**   | `—` (no UI of its own; member containers publish theirs on the pod) |
| **Storage**  | `~/containers/gluetun/state` (bind) → `/gluetun` |
| **Network**  | owns **`gluetun.pod`** — the shared netns + userns every member container joins |
| **Host deps**| `/dev/net/tun` (kernel tun device — present by default on Linux) |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
  (Pods + `UserNS=keep-id` need ≥ 4.4.)
- A **ProtonVPN** account with a **WireGuard** config: Proton portal →
  *Downloads → WireGuard configuration* → choose a **P2P** server, enable
  **Moderate NAT**, generate, and copy the `PrivateKey` into `.env` as
  `WIREGUARD_PRIVATE_KEY`.
- `/dev/net/tun` must exist (`ls -l /dev/net/tun`; `sudo modprobe tun` if missing).

## Deploy

```bash
mkdir -p ~/containers/gluetun/state
cp .env.example ~/containers/gluetun/.env    # edit WireGuard key, subnet, etc.
cp gluetun.pod gluetun.container ~/.config/containers/systemd/

# Mirror each riding app's port into the pod (Quadlet won't read .env for this):
#   gluetun.pod : PublishPort=<port>:<port>  — one line per app in the pod

systemctl --user daemon-reload
systemctl --user start gluetun
```

Then start whatever rides it (e.g. `systemctl --user start qbittorrent`).

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

## Verify

```bash
systemctl --user status gluetun               # active; healthy
podman exec gluetun wget -qO- https://ipinfo.io/ip   # the VPN exit IP, NOT your home IP
```

## Backup

```bash
# bind mount — tar gluetun's runtime state:
tar czf gluetun-$(date +%F).tar.gz -C ~/containers/gluetun/state .
```

## Notes

- **Connecting a future container to this VPN.** In its `<app>.container`:
  1. Add `Pod=gluetun.pod` — do **not** add your own `UserNS=` (inherited from
     the pod) or `Network=`/`PublishPort=` (the pod owns those).
  2. Add `Requires=gluetun.service` / `After=gluetun.service` to `[Unit]`.
  3. Add the app's port to `gluetun.pod`'s `PublishPort=` list, then
     `systemctl --user daemon-reload` and restart the pod's containers.
  All traffic from that container now exits through this tunnel — verify with
  the same `wget -qO- https://ipinfo.io/ip` check, run from inside *that*
  container, before trusting it.
- **Why a pod, not `Network=container:gluetun` (verified, the original design).**
  Joining another container's netns directly (`Network=container:<other>`)
  conflicts with `UserNS=keep-id` on the joining container — rootless Podman
  rejects the combination outright (`status=126`, container never created).
  Putting `UserNS=keep-id` on a **pod** instead, with every container (gluetun
  included) joining via `Pod=`, avoids the conflict and lets every member's
  PUID/PGID-based file ownership map to your real host UID. Caught live: with
  the direct-join design and no `keep-id`, a member's "PUID=1000" landed on the
  rootless subuid offset (e.g. host UID `100999`) instead of your real UID
  `1000` — every read/write to pre-existing bind-mounted files got "Permission
  denied."
- **`Environment=` with an embedded space must be quoted (verified, caused a
  real outage).** systemd parses an unquoted `Environment=VAR=val with spaces`
  as *multiple* assignments, silently dropping everything after the first
  space. `VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh /scripts/qbt-port.sh {{PORT}}`
  must be wrapped in quotes as one assignment, or the up-command silently runs
  a no-op shell and never fires the port-sync script.
- **Kill-switch teardown is total, not just network loss (verified, stricter
  than Docker).** When this container is removed (stop, restart, image
  update), Podman removes every `--rm` member container in the pod along with
  it — their shared netns just vanished — not merely cuts their network like
  Docker's `network_mode: service:` did. `Restart=always` on each member
  recovers them once this container is back; `StartLimitIntervalSec=120` /
  `StartLimitBurst=10` gives that recovery enough budget to survive a couple
  of quick back-to-back restarts (systemd's default 5-restarts/10s was
  exhausted testing this).
- **Security-baseline deviation (deliberate).** Keeps `DropCapability=ALL` but
  **adds `NET_ADMIN`** + `/dev/net/tun` (mandatory for WireGuard), plus
  **`DAC_OVERRIDE`** + **`CHOWN`** so the port-forwarding service can write and
  `chown` the runtime port file under `/tmp/gluetun`. Missing either aborts the
  PF service, so the up-command never runs.
- **DNS:** Encrypted DNS over TLS via Cloudflare — Quad9's DoT was reset on
  this route, breaking tracker resolution; Cloudflare resolves reliably.
- **Reverse proxy:** change the relevant `PublishPort=` in `gluetun.pod` to
  `127.0.0.1:<port>:<port>` and front it with your proxy.

---
_⚠️ UNTESTED on this host in its current (pod) form. An earlier design —
gluetun standalone with qBittorrent joining via `Network=container:gluetun`,
no pod — WAS tested live on `raspberrypi` (Pi 4B, Debian 13 Trixie, Podman
5.4.2) on 2026-06-28: tunnel up, Swiss ProtonVPN exit IP confirmed (no leak),
port forwarding + `qbt-port.sh` auto-sync verified end-to-end after the
`Environment=` quoting fix, kill-switch teardown confirmed. That design was
then replaced with the `gluetun.pod` structure here because it broke
`UserNS=keep-id` (real UID mapping) for the riding container — see Notes.
The tunnel mechanics above carry over unchanged; the pod plumbing itself
(`UserNS=keep-id` at pod level, multi-container pod start order) has not yet
been run. Replace this with `Tested on: <host>, <YYYY-MM-DD>` once verified._
