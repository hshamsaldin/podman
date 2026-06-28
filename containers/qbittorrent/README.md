# qBittorrent (via gluetun / ProtonVPN)

BitTorrent client whose traffic is forced entirely through a ProtonVPN
WireGuard tunnel — if the VPN drops, qBittorrent has no network (kill switch).

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [linuxserver/qbittorrent](https://github.com/linuxserver/docker-qbittorrent) · [qdm12/gluetun](https://github.com/qdm12/gluetun) |
| **Image**    | `lscr.io/linuxserver/qbittorrent:latest` · `docker.io/qmcgaw/gluetun:latest` |
| **Web UI**   | `http://<host>:8080` (qBittorrent, published *on gluetun*) |
| **Storage**  | `~/containers/qbittorrent/{config,gluetun,scripts}` (bind) · downloads disk → `/downloads` (bind) |
| **Network**  | qBittorrent runs in **gluetun's** netns (`Network=container:gluetun`); only gluetun publishes ports |
| **Host deps**| `/dev/net/tun` (kernel tun device — present by default on Linux) |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
  (`Network=container:` needs ≥ 4.4.)
- A **ProtonVPN** account with a **WireGuard** config: Proton portal →
  *Downloads → WireGuard configuration* → choose a **P2P** server, enable
  **Moderate NAT**, generate, and copy the `PrivateKey` into `.env` as
  `WIREGUARD_PRIVATE_KEY`.
- A downloads location on the host for the `/downloads` mount.
- `/dev/net/tun` must exist (`ls -l /dev/net/tun`; `sudo modprobe tun` if missing).

## Deploy

> ⚠️ UNTESTED on the host — verify the VPN leak check below before trusting.

```bash
mkdir -p ~/containers/qbittorrent
cp .env.example ~/containers/qbittorrent/.env    # edit WireGuard key, PUID/PGID, subnet
cp -r scripts ~/containers/qbittorrent/          # qbt-port.sh, mounted into gluetun
cp gluetun.container qbittorrent.container ~/.config/containers/systemd/

# config must be owned by your host user (rootless + keep-id):
mkdir -p ~/containers/qbittorrent/config ~/containers/qbittorrent/gluetun

# Mirror the non-interpolated bits into the units (Quadlet won't read .env for these):
#   gluetun.container    : PublishPort=8080:8080  (or 127.0.0.1:8080:8080 behind a proxy)
#   qbittorrent.container: Volume=<downloads>:/downloads  (default /data/downloads)

systemctl --user daemon-reload
systemctl --user start gluetun qbittorrent
```

The first WebUI login is `admin` + a **temporary password printed in the logs**:

```bash
podman logs qBittorrent | grep -i password
```

Open `http://<host>:8080`, log in, change the password, and set the save path to
`/downloads` (e.g. `/downloads/complete`).

## Upgrade

```bash
podman auto-update                            # pulls + restarts changed units
```

## Verify

```bash
systemctl --user status gluetun qbittorrent   # both active; gluetun healthy

# Confirm qBittorrent's traffic actually exits via the VPN — prints the ProtonVPN
# exit IP (NOT your home IP). If it shows your real IP, STOP.
podman exec qBittorrent wget -qO- https://ipinfo.io/ip

# Kill-switch check: stop gluetun, then qBittorrent should have NO network.
systemctl --user stop gluetun
podman exec qBittorrent wget -qO- https://ipinfo.io/ip   # must FAIL/hang
systemctl --user start gluetun
```

## Backup

```bash
# bind mount — tar the qBittorrent config (downloads are not backed up here):
tar czf qbittorrent-$(date +%F).tar.gz -C ~/containers/qbittorrent/config .
```

## Notes

- **Two units, one folder.** Deviation from "one container = one unit": gluetun is
  qBittorrent's inseparable VPN sidecar, so they share this folder. `gluetun.container`
  owns the netns and ports; `qbittorrent.container` joins via `Network=container:gluetun`.
- **The kill switch is the whole point.** qBittorrent has no network stack of its
  own — no `PublishPort`/`Network` bridge; those live on gluetun. Always run the
  **Verify** IP check after any change; a slip that detaches qBittorrent from
  gluetun's netns would leak your real IP.
- **No `UserNS=keep-id` on qBittorrent (verified, Podman-specific).** Rootless
  Podman rejects `UserNS=keep-id` combined with `Network=container:gluetun` —
  joining another container's netns can't also set up a separate user namespace
  (the unit fails with `status=126`, container never created). This is harmless
  here: the linuxserver/s6 image already remaps to `PUID`/`PGID` internally on its
  own — that's what those two `.env` vars are for — so dropping `keep-id` costs
  nothing. (Jellyfin needs `keep-id` precisely because it has no such logic.)
- **Ordering vs. health (Podman-specific).** Docker used `depends_on: condition:
  service_healthy`. Quadlet/systemd express ordering with `Requires=`/`After=` on
  `gluetun.service`, which guarantees gluetun's container (and netns) exists first,
  but **not** that the tunnel is fully up before qBittorrent starts. That's fine:
  the kill switch still holds (no tunnel = no traffic), and `qbt-port.sh` retries
  for 5 min. If you want strict "wait for healthy," add a `systemd` drop-in that
  polls `podman healthcheck run gluetun` before starting qBittorrent.
- **WebUI is published on gluetun.** Reaching it from the LAN also needs
  `FIREWALL_OUTBOUND_SUBNETS` (in `.env`) so gluetun doesn't drop the return
  packets. If the WebUI is unreachable from other machines, check that subnet first.
- **Port forwarding is auto-wired.** On each port assign/renew gluetun runs
  `scripts/qbt-port.sh` (mounted at `/scripts`, via `VPN_PORT_FORWARDING_UP_COMMAND`),
  which POSTs the new port to qBittorrent's WebUI API on `127.0.0.1:8080` (same
  netns), retrying up to 5 min. **One-time setup:** qBittorrent → Settings → Web UI,
  tick **"Bypass authentication for clients on localhost"**, and untick **"Use
  UPnP/NAT-PMP"** under Connection. Verify with
  `podman exec gluetun cat /tmp/gluetun/forwarded_port` vs qBittorrent's listening port.
- **Security-baseline deviations** (deliberate):
  - gluetun keeps `DropCapability=ALL` but **adds `NET_ADMIN`** + `/dev/net/tun`
    (mandatory for WireGuard), plus **`DAC_OVERRIDE`** + **`CHOWN`** so its
    port-forwarding service can write and `chown` the runtime port file under
    `/tmp/gluetun`. Missing either aborts the PF service, so the up-command never runs.
  - qBittorrent is a linuxserver/s6 image; `DropCapability=ALL`/`ReadOnly` are **not**
    applied (unverified against its init, would risk a crash-loop). `NoNewPrivileges`
    kept on both.
  - Memory caps (`--memory=256m` gluetun / `1g` qBittorrent) via `PodmanArgs`. On a
    Pi they're discarded until the memory cgroup is enabled (`cgroup_enable=memory
    cgroup_memory=1` in `/boot/firmware/cmdline.txt` + reboot).
- **Rootless caveats (Podman-specific).** `UserNS=keep-id` maps your host UID 1:1
  so downloads stay yours; PUID/PGID in `.env` must equal your `id -u`/`id -g`.
  `NET_ADMIN` + `/dev/net/tun` work inside the rootless user namespace; if WireGuard
  fails to come up, confirm `/dev/net/tun` is readable by your user.
- **Reverse proxy:** set `gluetun.container` `PublishPort=127.0.0.1:8080:8080` and
  front gluetun with your proxy.

---
_⚠️ UNTESTED on this host — Quadlet translation of the tested Docker stack
([docker repo](https://github.com/hshamsaldin/docker/tree/main/containers/qbittorrent)),
where the leak check returned a Swiss ProtonVPN exit IP (no leak), Cloudflare DoT
resolved trackers, and auto port-forwarding was verified end-to-end. The rootless
Podman path (keep-id, netns sharing, PF up-command) needs host verification.
Replace with `Tested on: <host>, <YYYY-MM-DD>` once Deploy + Verify have run._
