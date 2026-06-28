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

- The [gluetun](../gluetun) container deployed first — it owns the pod and
  the tunnel. qBittorrent has nothing to configure VPN-side.
- A downloads location on the host for the `/downloads` mount.
- This pod runs **without** `UserNS=` (gluetun's firewall hard-requires it off
  — see [gluetun's README](../gluetun)), so qBittorrent's `PUID` does **not**
  map to your real host UID. Any path you bind-mount that already has real
  files on it needs a one-time ownership fix — see Deploy, and
  [docs/host-setup.md](../../docs/host-setup.md) → "Finding a container's REAL
  host UID" for why/how this number is derived (never hardcoded).

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

# ONE-TIME: derive the real host UID your PUID resolves to (this pod has no
# UserNS=, so it is NOT your own UID — see Prerequisites). Run from the repo root:
../../scripts/derive-rootless-uid.sh 1000      # match your .env's PUID
# -> prints a host UID, e.g. 100999. Use THAT number below, not this example.

# Apply it to whatever already has real files on it:
sudo chown -R <result>:<result> ~/containers/qbittorrent/config
# If your downloads disk is a NATIVE filesystem (ext4/xfs/btrfs):
sudo chown -R <result>:<result> /data/downloads        # match your real downloads path
# If it's a FOREIGN filesystem (NTFS/exFAT via ntfs-3g/exfat), chown is a
# no-op — ownership is faked uniformly from the mount's uid=/gid= option.
# Set that option to <result> in /etc/fstab instead, then:
sudo systemctl daemon-reload
sudo systemctl stop <your-app>.service 2>/dev/null   # release anything with the disk open
sudo systemctl stop data.mount && sudo fuser -v /data  # READ-ONLY check, see what's open
# Only proceed once nothing unexpected is listed -- never `fuser -k` a live
# mountpoint, it can kill far more than intended (verified the hard way: it
# took out core system services here, not just the stale mount process).
sudo systemctl start data.mount

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
- **No `UserNS=` anywhere in this pod — deliberate, three designs tried.**
  1. Direct `Network=container:gluetun` + `UserNS=keep-id` on qBittorrent:
     rejected outright (`status=126`, container never created).
  2. Pod-level `keep-id` (on `gluetun.pod`): let qBittorrent map correctly,
     but **gluetun's container wouldn't start at all** — its internal
     nftables kill-switch hard-fails under `keep-id`'s fragmented UID mapping,
     with no documented way to disable it (checked gluetun's source/wiki
     directly — see [gluetun's README](../gluetun)).
  3. `UserNS=keep-id` on **just** qBittorrent, still joined via `Pod=` (not a
     direct netns join): rootless Podman rejects this identically to #1
     (`status=126`) — matches open upstream bugs
     [containers/podman#26889](https://github.com/containers/podman/issues/26889),
     [#22931](https://github.com/containers/podman/issues/22931).
  So: no `UserNS=` anywhere in this pod, full stop. gluetun's firewall works,
  and qBittorrent's `PUID` lands on a rootless subuid offset instead of your
  real UID. **Consequence:** any pre-existing file (migrated config, an
  existing downloads library) needs a one-time ownership fix to the *derived*
  UID — see Deploy and
  [docs/host-setup.md](../../docs/host-setup.md). Files qBittorrent creates
  itself going forward are self-consistent; only pre-existing data needs the
  fix, once. `podman unshare chown` is **not** reliable for this — it
  computes its translation from your session's default mapping, which does
  not always match a specific pod member's actual resolved UID (confirmed
  live: it silently failed here). Always derive the real number from the
  kernel (`docs/host-setup.md`'s script) and `chown`/set the mount option to
  that exact value directly.
- **Foreign-filesystem (NTFS/exFAT) downloads disk needs the MOUNT's owner
  changed, not the files (verified, this is what actually fixed it here).**
  `ntfs-3g`/`exfat` fake Unix ownership entirely from `/etc/fstab`'s
  `uid=`/`gid=` option — there's no real per-file ownership to `chown`. If
  your downloads disk is on one of these, set that mount option to the
  derived UID (above), not to your own. Keep the same `umask` — this isn't a
  permission loosening, just pointing the existing owner-only-write rule at
  the right owner. Other readers of the same disk (e.g. Jellyfin, via its own
  `keep-id` + real UID) keep working because they only need *read*, which the
  mount's `umask` still grants to non-owners.
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
- **PUID/PGID** in `.env`: leave at `1000:1000` (or whatever's simplest to
  remember) even though it no longer maps to your real host UID — it only
  needs to be *consistent* with whatever you derived and applied in Deploy.

---
_Tested on: `raspberrypi` (Pi 4B, Debian 13 Trixie, Podman 5.4.2), 2026-06-28 —
full stack migrated live from Docker. gluetun: tunnel up, ProtonVPN exit IP
confirmed (no leak), port forwarding + `qbt-port.sh` auto-sync verified
end-to-end. qBittorrent: derived its real host UID (`100999` on this host,
via the `docs/host-setup.md` formula), applied it to the downloads disk's
`ntfs-3g` mount (`uid=`/`gid=` in `/etc/fstab` — `chown` is a no-op on that
filesystem) and to the `config` bind mount (`chown`, ext4) — confirmed via
the real daemon UID (`podman exec --user 1000:1000 ... touch`, not the
default root exec, which would have falsely passed). Kill-switch teardown
confirmed (stopping gluetun removes qBittorrent's container too; both
self-recover via `Restart=always` once gluetun is back). Three `UserNS=`
designs tried and rejected before landing on "none" — see Notes._
