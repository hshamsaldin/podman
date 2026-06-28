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
| **Network**  | owns **`gluetun.pod`** — the shared netns every member container joins (deliberately **no** `UserNS=keep-id` — see Notes) |
| **Host deps**| `/dev/net/tun` (kernel tun device — present by default on Linux) |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md). (Pods need ≥ 4.4.)
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

- **No `UserNS=` on this pod, and none on any member either — deliberate,
  verified, no workaround exists.** Three designs tried before landing here:
  1. *Direct join* (`Network=container:gluetun` on the riding container, no
     pod) + `UserNS=keep-id` on that container: rootless Podman rejects the
     combination outright (`status=126`, container never created).
  2. *Pod with `UserNS=keep-id`* (on the pod itself): avoided conflict #1,
     but gluetun's internal nftables kill-switch then refused to start —
     `ERROR creating iptables firewall: ... Permission denied (you must be
     root)` on **all three** iptables backends, container exits immediately.
     Checked gluetun's source and wiki directly: there is **no** documented
     `FIREWALL=off` or equivalent — the firewall is a hard, non-optional
     requirement. The kernel's nft "rule set generation id" check only trusts
     a single contiguous UID mapping starting at 0 (what plain default
     rootless mapping gives you); `keep-id` has to splice your real UID into
     the middle of that range, producing a fragmented mapping nft rejects.
  3. `UserNS=keep-id` on **just** the riding container (still joined via
     `Pod=`, not a direct netns join — testing whether pod membership avoids
     conflict #1 since pods don't necessarily share userns): rejected
     identically to #1 (`status=126`). Matches open upstream bugs
     [containers/podman#26889](https://github.com/containers/podman/issues/26889),
     [#22931](https://github.com/containers/podman/issues/22931).
  So: no `UserNS=` anywhere, full stop. gluetun's firewall works, but every
  member container loses its 1:1 host-UID mapping. See
  [qBittorrent's README](../qbittorrent) for the resulting trade-off — a
  one-time, *derived* (never hardcoded) UID fix applied directly to whatever
  bind-mounted paths already have real files on them, via
  [docs/host-setup.md](../../docs/host-setup.md).
- **Connecting a future container to this VPN.** In its `<app>.container`:
  1. Add `Pod=gluetun.pod` — do **not** add your own `UserNS=` (this pod has
     none — adding `keep-id`, even just to your one container, breaks either
     the whole pod's firewall or fails outright; see above) or
     `Network=`/`PublishPort=` (the pod owns those).
  2. Add `Requires=gluetun.service` / `After=gluetun.service` to `[Unit]`.
  3. Add the app's port to `gluetun.pod`'s `PublishPort=` list, then
     `systemctl --user daemon-reload` and restart the pod's containers.
  4. If that container bind-mounts pre-existing host files, derive its real
     UID (`docs/host-setup.md`'s script) and apply it directly — `chown` for
     a native filesystem, the mount's `uid=`/`gid=` option for NTFS/exFAT
     (see [qBittorrent's README](../qbittorrent) for the worked example).
  All traffic from that container now exits through this tunnel — verify with
  the same `wget -qO- https://ipinfo.io/ip` check, run from inside *that*
  container, before trusting it.
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
_Tested on: `raspberrypi` (Pi 4B, Debian 13 Trixie, Podman 5.4.2), 2026-06-28 —
full stack migrated live from Docker. Tunnel up, WireGuard connected,
ProtonVPN exit IP confirmed (no leak), port forwarding + `qbt-port.sh`
auto-sync verified end-to-end after the `Environment=` quoting fix.
Kill-switch teardown confirmed (stopping this container removes every other
pod member's `--rm` container too; both self-recover via `Restart=always`).
Three `UserNS=` designs tried and rejected (see Notes) before landing on
"none anywhere in this pod" — qBittorrent's resulting UID-mapping trade-off
verified working via its own README's derived-UID fix, confirmed with the
real daemon UID (not exec's default root, which would have falsely passed)._
