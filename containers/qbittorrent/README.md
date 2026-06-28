# qBittorrent (via gluetun / ProtonVPN)

BitTorrent client whose traffic is forced entirely through a ProtonVPN
WireGuard tunnel — if the VPN drops, qBittorrent has no network (kill switch).

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [linuxserver/qbittorrent](https://github.com/linuxserver/docker-qbittorrent) |
| **Image**    | `lscr.io/linuxserver/qbittorrent:latest` |
| **Web UI**   | `http://<host>:8080` (published on the **pod**, not this container) |
| **Storage**  | `~/containers/qbittorrent/{config,scripts}` (bind) · downloads disk → `/downloads` (bind) |
| **Network**  | joins the shared **[gluetun](../gluetun) pod** (`Pod=gluetun.pod`) — see that container for the VPN tunnel itself |
| **Host deps**| none beyond [gluetun](../gluetun)'s |

## Prerequisites

- The [gluetun](../gluetun) container deployed first — it owns the pod, the
  tunnel, and `UserNS=keep-id`. qBittorrent has nothing to configure VPN-side.
- A downloads location on the host for the `/downloads` mount.

## Deploy

> ⚠️ UNTESTED on the host — verify the VPN leak check below before trusting.

```bash
mkdir -p ~/containers/qbittorrent/config
cp .env.example ~/containers/qbittorrent/.env    # edit PUID/PGID/TZ
cp -r scripts ~/containers/qbittorrent/          # qbt-port.sh, mounted into gluetun
cp qbittorrent.container ~/.config/containers/systemd/

# Mirror the non-interpolated bits into the unit (Quadlet won't read .env for these):
#   qbittorrent.container: Volume=<downloads>:/downloads  (default /data/downloads)
# And confirm gluetun.pod (in ../gluetun) publishes 8080 for this app.

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

- **Rides the shared [gluetun](../gluetun) pod, not its own netns.** gluetun
  used to be qBittorrent-specific infrastructure; it's now a standalone shared
  VPN pod any container can join (see gluetun's README for how to connect a
  future container the same way). This container only needs `Pod=gluetun.pod`
  in its `[Container]` section plus `Requires=`/`After=gluetun.service` — no
  `PublishPort=`, `Network=`, or `UserNS=` of its own; the pod owns all three.
- **The kill switch is the whole point.** qBittorrent has no network stack of
  its own. Always run the **Verify** IP check after any change; a slip that
  detaches it from the pod would leak your real IP.
- **Kill-switch teardown is total, not just network loss (verified, stricter than
  Docker).** When gluetun's container is removed (manual stop, restart, image
  update), Podman removes qBittorrent's `--rm` container right along with it —
  its shared netns just vanished — not merely cuts its network like Docker's
  version did. `Restart=always` + `Requires=`/`After=` bring it back once
  gluetun is up again; `StartLimitIntervalSec=120`/`StartLimitBurst=10` gives
  that recovery enough budget to survive a couple of quick back-to-back gluetun
  restarts (systemd's default 5-restarts/10s was exhausted testing this and left
  qBittorrent `inactive (dead)` until a manual `systemctl --user start
  qbittorrent`). If it's ever sitting inactive after a real gluetun blip:
  `systemctl --user reset-failed qbittorrent; systemctl --user start qbittorrent`.
- **No `UserNS=` here at all (verified, Podman-specific — this is the whole
  reason the pod exists).** The original design had qBittorrent join gluetun
  directly via `Network=container:gluetun`, with `UserNS=keep-id` dropped
  because rootless Podman rejects that combination (`status=126`, container
  never created). But dropping `keep-id` meant qBittorrent's internal
  `PUID=1000` landed on the rootless subuid offset (host UID `100999`) instead
  of your real UID `1000` — every read/write to pre-existing downloaded files
  got "Permission denied" (confirmed live on a real torrent). Moving
  `UserNS=keep-id` to the **pod** (`gluetun.pod`) and having both containers
  join via `Pod=` fixes this: the pod's userns is shared by every member, no
  per-container conflict, and `PUID=1000` now correctly maps to your real host
  UID `1000` again.
- **Ordering vs. health (Podman-specific).** Docker used `depends_on: condition:
  service_healthy`. Quadlet/systemd express ordering with `Requires=`/`After=` on
  `gluetun.service`, which guarantees gluetun's container (and the pod's netns)
  exists first, but **not** that the tunnel is fully up before qBittorrent
  starts. That's fine: the kill switch still holds (no tunnel = no traffic),
  and `qbt-port.sh` retries for 5 min.
- **WebUI is published on the pod.** Reaching it from the LAN also needs
  `FIREWALL_OUTBOUND_SUBNETS` (in gluetun's `.env`) so gluetun doesn't drop the
  return packets. If the WebUI is unreachable from other machines, check that
  subnet first.
- **Port forwarding is auto-wired** by gluetun (`scripts/qbt-port.sh`, owned by
  this container's folder but run by gluetun on each port renewal) — see
  [gluetun's README](../gluetun) for the full mechanism and the
  `Environment=` quoting fix that made it actually fire. **One-time setup:**
  qBittorrent → Settings → Web UI, tick **"Bypass authentication for clients on
  localhost"**, and untick **"Use UPnP/NAT-PMP"** under Connection.
- **Security-baseline deviation (deliberate).** This is a linuxserver/s6 image;
  `DropCapability=ALL`/`ReadOnly` are **not** applied (unverified against its
  init, would risk a crash-loop). `NoNewPrivileges` is kept. `--memory=1g` via
  `PodmanArgs` is discarded on a Pi until the memory cgroup is enabled
  (`cgroup_enable=memory cgroup_memory=1` in `/boot/firmware/cmdline.txt` + reboot).
- **PUID/PGID** in `.env` must equal your real `id -u`/`id -g` — the pod's
  `UserNS=keep-id` is what makes that mapping land correctly on the host.

---
_⚠️ UNTESTED on this host — Quadlet translation of the tested Docker stack
([docker repo](https://github.com/hshamsaldin/docker/tree/main/containers/qbittorrent)).
An earlier non-pod design WAS tested live (leak check returned a Swiss
ProtonVPN exit IP, Cloudflare DoT resolved trackers, auto port-forwarding
verified end-to-end) but broke file permissions for this container — see
Notes and [gluetun's README](../gluetun). The current pod-based structure
needs fresh host verification. Replace with `Tested on: <host>, <YYYY-MM-DD>`
once Deploy + Verify have run._
