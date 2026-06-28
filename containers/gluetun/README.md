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

- **No `UserNS=keep-id` on this pod — deliberate, verified, no workaround
  exists.** This pod went through two failed designs before landing here:
  1. *Direct join* (`Network=container:gluetun` on the riding container, no
     pod): rootless Podman rejects `UserNS=keep-id` combined with
     `Network=container:<other>` outright (`status=126`, container never
     created).
  2. *Pod with `UserNS=keep-id`*: avoided that conflict, but gluetun's
     internal nftables kill-switch then refused to start —
     `ERROR creating iptables firewall: ... Permission denied (you must be
     root)` on **all three** iptables backends, container exits immediately.
     Checked gluetun's source and wiki directly: there is **no** documented
     `FIREWALL=off` or equivalent — the firewall is a hard, non-optional
     requirement. The kernel's nft "rule set generation id" check only trusts
     a single contiguous UID mapping starting at 0 (what plain default
     rootless mapping gives you); `keep-id` has to splice your real UID into
     the middle of that range, producing a fragmented mapping nft rejects.
  This pod therefore runs with **no `UserNS=` line at all** (Podman's default
  rootless mapping) — gluetun's firewall works, but it costs every member
  container its 1:1 host-UID mapping. See
  [qBittorrent's container file](../qbittorrent/qbittorrent.container) for
  the resulting trade-off and the `podman unshare chown` fix it requires for
  pre-existing bind-mounted files.
- **Connecting a future container to this VPN.** In its `<app>.container`:
  1. Add `Pod=gluetun.pod` — do **not** add your own `UserNS=` (this pod has
     none — adding `keep-id` to fix *your* container's file ownership will
     break gluetun's firewall for the *whole* pod) or `Network=`/`PublishPort=`
     (the pod owns those).
  2. Add `Requires=gluetun.service` / `After=gluetun.service` to `[Unit]`.
  3. Add the app's port to `gluetun.pod`'s `PublishPort=` list, then
     `systemctl --user daemon-reload` and restart the pod's containers.
  4. If that container bind-mounts pre-existing host files, fix their
     ownership once with `podman unshare chown -R <uid>:<gid> <path>` (see
     qBittorrent's container file for the full explanation).
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
_⚠️ UNTESTED on this host in its current (pod, no keep-id) form. Two earlier
designs were tried and rejected live on `raspberrypi` (Pi 4B, Debian 13
Trixie, Podman 5.4.2) on 2026-06-28 — see Notes for both failures
(`status=126` direct-join, then gluetun's iptables hard-failing under
pod-level `keep-id`). The underlying tunnel mechanics (WireGuard, exit IP,
port forwarding, `qbt-port.sh` auto-sync after the `Environment=` quoting
fix, kill-switch teardown) were all confirmed working under the first
(non-pod) design before the restructure. This current no-keep-id pod design
has not yet been run end-to-end. Replace with `Tested on: <host>,
<YYYY-MM-DD>` once Deploy + Verify (including the `podman unshare chown` fix
and a working qBittorrent write test) have actually run._
