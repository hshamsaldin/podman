# NetBird

WireGuard-based mesh VPN client — registers this host as a NetBird peer.

|              |                                              |
|--------------|----------------------------------------------|
| **Upstream** | [netbirdio/netbird](https://github.com/netbirdio/netbird) |
| **Image**    | `docker.io/netbirdio/netbird:latest`         |
| **Web UI**   | `—` (CLI: `podman exec NetBird netbird status`) |
| **Storage**  | `netbird-client` (named volume) → `/var/lib/netbird` |
| **Network**  | default rootless network (no published ports) + `NET_ADMIN`/`NET_RAW` / `/dev/net/tun` |
| **Host deps**| `/dev/net/tun`                               |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
- `/dev/net/tun` present (`ls -l /dev/net/tun`; `sudo modprobe tun` if missing).
- **First registration only:** a NetBird setup key. Podman starts from an empty
  `netbird-client` volume (Docker's volume does not carry over — see Notes), so
  the peer must register fresh. Uncomment `NB_SETUP_KEY=` in `netbird.container`
  for the first start, then remove it — credentials then live in the volume.

## Deploy

> ⚠️ UNTESTED on the host — verify before trusting.

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
FQDN: pi.netbird.cloud
NetBird IP: 100.x.x.x/16
```

Confirm the data volume is attached and the unit is healthy:

```bash
systemctl --user status netbird
podman inspect -f '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}' NetBird
# -> netbird-client -> /var/lib/netbird
```

## Backup

⚠️ UNTESTED — registration state (peer keys + session) lives in the
`netbird-client` volume:

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
  `podman unshare`. Re-registering with a key is simpler. ⚠️ UNTESTED.
- **Named volume** (`netbird-client.volume`): recreating the container reuses the
  existing registration; don't delete the volume or you must re-register.
- Keeps `NET_ADMIN` + `/dev/net/tun` (required for the WireGuard interface),
  **and `NET_RAW`** (verified required — without it, `netbird status` fails
  with `failed to create ipv4 raw socket: socket: operation not permitted`;
  NetBird uses raw sockets for ICMP-based connectivity checks).
- **Rootless WireGuard + raw sockets** both work inside the container's user
  namespace; the capabilities are added within that userns, not on the host —
  no extra host-side privilege needed, unlike gluetun's nftables requirement.

---
_⚠️ UNTESTED on this host — Quadlet translation of the tested Docker stack
([docker repo](https://github.com/hshamsaldin/docker/tree/main/containers/netbird))._
_Replace with `Tested on: <host>, <YYYY-MM-DD>` once Deploy + Upgrade have run._
