# NetBird

WireGuard-based mesh VPN client — registers this host as a NetBird peer.

|              |                                              |
|--------------|----------------------------------------------|
| **Upstream** | [netbirdio/netbird](https://github.com/netbirdio/netbird) |
| **Image**    | `docker.io/netbirdio/netbird:latest`         |
| **Web UI**   | `—` (CLI: `podman exec NetBird netbird status`) |
| **Storage**  | `netbird-client` (named volume) → `/var/lib/netbird` |
| **Network**  | default rootless network (no published ports) + `NET_ADMIN`/`NET_RAW` / `/dev/net/tun`. **LAN-routing peer use case requires rootful instead — see Notes.** |
| **Host deps**| `/dev/net/tun`                               |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
- `/dev/net/tun` present (`ls -l /dev/net/tun`; `sudo modprobe tun` if missing).
- **First registration only:** a NetBird setup key. Podman starts from an empty
  `netbird-client` volume (Docker's volume does not carry over — see Notes), so
  the peer must register fresh. Uncomment `NB_SETUP_KEY=` in `netbird.container`
  for the first start, then remove it — credentials then live in the volume.
- **If you need this peer to route traffic to other LAN devices** (not just
  reach this host itself), the default rootless deploy below is **not
  sufficient** — see "Routing peer (LAN access)" under Notes before deploying.

## Deploy

```bash
cp netbird.container netbird-client.volume ~/.config/containers/systemd/
# edit netbird.container: set NB_SETUP_KEY for the very first start
systemctl --user daemon-reload
systemctl --user start netbird
```

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

## Verify

Use the container name so it works from anywhere:

```bash
podman exec NetBird netbird status
```

Expected (shape):

```
Management: Connected
Signal: Connected
FQDN: <hostname>.netbird.cloud
NetBird IP: 100.x.x.x/16
```

Confirm the data volume is attached and the unit is healthy:

```bash
systemctl --user status netbird
podman inspect -f '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}' NetBird
# -> netbird-client -> /var/lib/netbird
```

## Backup

Registration state (peer keys + session) lives in the `netbird-client` volume:

```bash
podman volume export netbird-client -o netbird-$(date +%F).tar
```

## Notes

- **Docker volume does not carry over.** Under Docker this used an `external`
  volume `netbird-client`; Podman has a separate volume store, so this stack
  starts from a fresh volume and the peer **re-registers** with a new setup key.
  To instead migrate the old state, export the Docker volume on the old setup
  (`docker run --rm -v netbird-client:/d -v "$PWD":/b alpine tar czf /b/nb.tgz -C /d .`),
  create the Podman volume, and untar into it via `podman volume import` /
  `podman unshare`. Re-registering with a key is simpler.
- **Named volume** (`netbird-client.volume`): recreating the container reuses the
  existing registration; don't delete the volume or you must re-register.
- Keeps `NET_ADMIN` + `/dev/net/tun` (required for the WireGuard interface),
  **and `NET_RAW`** (verified required — without it, `netbird status` fails
  with `failed to create ipv4 raw socket: socket: operation not permitted`;
  NetBird uses raw sockets for ICMP-based connectivity checks).
- **Rootless WireGuard + raw sockets** both work inside the container's user
  namespace for basic peer connectivity (this host reaching the mesh, and the
  mesh reaching this host); the capabilities are added within that userns, not
  on the host — no extra host-side privilege needed for that case, unlike
  gluetun's nftables requirement.
- **Routing peer (LAN access) — requires rootful, not rootless.** If this peer
  needs to forward traffic to *other* devices on the LAN (advertised via
  NetBird's Network Routes / "Networks" feature), the rootless deploy above is
  not enough, even with the route correctly configured in the NetBird
  dashboard. Acting as a routing peer means NetBird must modify the **host's
  real routing table / iptables**, which requires genuine root-level
  `CAP_NET_ADMIN`. Rootless Podman's `AddCapability=NET_ADMIN` is scoped to the
  container's user namespace only — it does not translate to real host
  capability, and `Network=host` does **not** grant it either (verified live:
  `Error: status failed: create wg interface: recreate: link add: operation
  not permitted`). This mirrors Docker's behavior too — Docker's daemon runs
  as root, which is *why* `--network=host --cap-add=NET_ADMIN` works there;
  it is not something Podman uniquely lacks (confirmed against
  [containers/podman#7816](https://github.com/containers/podman/issues/7816)
  and NetBird's own docs, which note their dedicated `rootless` image variant
  is explicitly limited to "inbound access ... no outbound connections except
  via socks proxy" — i.e. it cannot do LAN-routing peer duty either).

  **Fix: deploy this unit rootful instead**, as a system-level Quadlet unit:
  ```bash
  sudo mkdir -p /etc/containers/systemd/
  sudo cp netbird.container netbird-client.volume /etc/containers/systemd/
  # edit /etc/containers/systemd/netbird.container:
  #   - set NB_SETUP_KEY for first start (different volume store than rootless —
  #     this is a fresh peer registration even if you already ran the rootless
  #     version; remove the old dashboard entry afterward)
  #   - add two more capabilities NetBird's own official Docker docs call for:
  #       AddCapability=SYS_ADMIN
  #       AddCapability=SYS_RESOURCE
  sudo systemctl daemon-reload
  sudo systemctl start netbird      # do NOT use `enable` — Quadlet-generated
                                     # units are transient; [Install] WantedBy=
                                     # already handles boot-start
  ```
  Also required on the host, independent of NetBird/Podman: confirm
  `net.ipv4.ip_forward=1` (see [host setup](../../docs/host-setup.md)), **and**
  `sudo ufw default allow routed` — ufw's default `FORWARD` chain policy is
  `DROP`, which silently breaks the rootful Podman bridge's outbound traffic
  (DNS lookups to the management server timed out with
  `i/o timeout` until this was set). This is the same fix `2-docker.sh`
  already applies for Docker's bridge — Podman's rootful `netavark` bridge
  needs it too, and it isn't automatic.

## Routing peer (LAN access) capability summary

The complete file you need on top of the standard `netbird.container`, deployed
to `/etc/containers/systemd/` (rootful) instead of `~/.config/containers/systemd/`:

```ini
[Container]
...
AddCapability=NET_ADMIN
AddCapability=NET_RAW
AddCapability=SYS_ADMIN
AddCapability=SYS_RESOURCE
AddDevice=/dev/net/tun
```

---
_Tested on: `raspberrypi` (Pi 4B, Debian 13 Trixie, Podman 5.4.2), 2026-06-28 —
migrated live from Docker as a fresh peer (rootless, basic connectivity only).
Came up with `Management: Connected`, `Signal: Connected`, `Relays: 4/4
Available`, and a real `NetBird IP` assigned. Required adding `NET_RAW` on top
of `NET_ADMIN` — see Notes._

_Tested on: `debian` (Debian 13 Trixie, Podman 5.4.2), 2026-06-29 — LAN-routing
peer use case (iPhone connected via NetBird reaching other LAN devices behind
this host) confirmed working, but only after redeploying **rootful** with
`SYS_ADMIN`/`SYS_RESOURCE` added and `sudo ufw default allow routed` applied —
see Notes for the full why. The rootless deploy alone never got past
`Management: Disconnected` for this use case._
