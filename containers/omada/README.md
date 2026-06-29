# Omada

TP-Link Omada SDN controller — manages the EAP APs, switches, and gateway. It is
a **control plane only**: APs/switches keep forwarding and the internet stays up
even while this container is stopped.

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [mbentley/docker-omada-controller](https://github.com/mbentley/docker-omada-controller) |
| **Image**    | `docker.io/mbentley/omada-controller:6.2.10.17` (pinned — see Notes) |
| **Web UI**   | `https://<host>:8043` (self-signed cert) |
| **Storage**  | `omada-data` / `omada-logs` (named volumes) → `/opt/tplink/EAPController/{data,logs}` |
| **Network**  | published LAN-wide (devices must reach the ports) |
| **Host deps**| `—`                                      |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
- The `omada-data` / `omada-logs` volumes. A **blank** `omada-data` comes up as a
  brand-new, empty controller — migrate the old controller's data in first
  (see Notes) or you lose all sites/devices. (Not needed for a fresh install.)
- **LAN ports must be opened in the host firewall** — ufw default-denies incoming,
  so allow at minimum `8043/tcp`, `8088/tcp`, `8843/tcp`, `19810/udp`, `27001/udp`,
  `29810/udp`, `29811:29817/tcp` (verified working set):
  ```bash
  sudo ufw allow 8043/tcp comment 'omada web UI / device adoption'
  sudo ufw allow 8088/tcp comment 'omada http manage'
  sudo ufw allow 8843/tcp comment 'omada guest portal'
  sudo ufw allow 19810/udp comment 'omada discovery'
  sudo ufw allow 27001/udp comment 'omada app discovery'
  sudo ufw allow 29810/udp comment 'omada discovery v1'
  sudo ufw allow 29811:29817/tcp comment 'omada manager/adopt/upgrade/transfer/rtty/monitor'
  ```

## Deploy

```bash
cp omada.container omada-data.volume omada-logs.volume ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start omada
```

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

> ⚠️ **Major-version jump caution still applies if you are migrating old data.**
> If coming from a Docker host running 5.13/5.14, do **not** leap straight to
> 6.x in one pull — step through a late `5.x` tag first, let the DB migration
> finish, then move to the pinned 6.x tag. Back up the volume (below) before
> each step; a migrated DB cannot be downgraded in place. This does not apply
> to a fresh install with no prior data.

## Verify

```bash
systemctl --user status omada
# UI: https://<host>:8043  (accept the self-signed cert)
# devices reconnect as Connected/Provisioned within ~2 min
```

## Backup

Two layers — do both before any upgrade:

1. **In-app export** (portable, version-safe): Global view → Settings → Maintenance
   → Backup & Restore → Export → `.cfg`.
2. **Volume snapshot** (instant rollback):

```bash
podman volume export omada-data -o omada-$(date +%F).tar
```

Verified working: in-app `.cfg` backup restored cleanly into a fresh 6.2.10.17
controller.

## Notes

- **Pinned to `6.2.10.17` instead of `:latest`.** At deploy time, `:latest`
  resolved to a stale cached `5.15.24.19` image (confirmed via the bundled jar
  filenames, e.g. `omada-web-5.15.24.19-local.jar`) — pulling `:latest` did not
  reliably give the newest controller version. Pinning the exact tag guarantees
  the intended version. Trade-off: `podman auto-update` now only refreshes
  *within* `6.2.10.17` (new builds of that same tag), not future major versions
  — revisit this pin periodically and bump deliberately.
- **Migrating the controller off Docker** (only relevant if carrying over an
  existing controller's data — skip entirely for a fresh install).
  Podman cannot see Docker's volumes, so the controller's entire state must be
  copied across, or you get a blank controller. On the **old Docker** setup, dump
  the data volume, then load it into the new Podman volume:
  ```bash
  # 1. on the Docker host — export the live data volume:
  docker run --rm -v hussein_omada-data:/d -v "$PWD":/b alpine \
    tar czf /b/omada-data.tgz -C /d .
  # 2. on the Podman host — create the volume (start+stop once, or `podman volume create omada-data`)
  #    then restore into it:
  podman volume create omada-data
  podman run --rm -v omada-data:/d -v "$PWD":/b docker.io/library/alpine \
    tar xzf /b/omada-data.tgz -C /d
  ```
  Prefer the **in-app `.cfg` export/import** (Backup §1) over a raw volume copy
  when crossing the 5.x → 6.x version boundary — it's the version-safe path,
  and the one actually verified working on this host.
- **Named volumes:** recreating the container reuses the controller state. Never
  delete `omada-data`, or you lose all sites/devices.
- **PUID/PGID 508** are the upstream image's documented default and were kept
  as-is for a fresh install — adjust if you migrate in data owned by a
  different UID/GID.
- **Security-baseline deviations** (deliberate): `DropCapability`, `ReadOnly`,
  `NoNewPrivileges`, and a memory cap are intentionally **omitted** — the
  controller runs MongoDB + a JVM and tightening caps against this image is
  unverified. Mirrors mbentley's proven upstream config.
- **Ports are LAN-wide.** APs/switches/gateway adopt and inform over
  `8043`/`29810-29817`/etc., so they cannot sit behind a localhost-only bind.
- **Rootless source-IP caveat:** rootless port publishing can rewrite the source
  IP of inbound device traffic (slirp4netns more so than pasta). Podman ≥ 5
  with `pasta` (in use here) preserves source IPs better; no adoption/inform
  issues observed on this host.
- **Firmware upgrade "Operation failed. Please check your network connection"**:
  this is the controller failing to reach TP-Link's cloud firmware-check
  service, unrelated to Podman/rootless networking — verify with
  `podman exec Omada wget -qO- -T5 <tp-link cloud endpoint>` and host-level
  DNS (`nslookup`). Workaround that bypasses the cloud dependency entirely:
  download the firmware `.bin` manually from TP-Link's download center and use
  **Local Upgrade** (manual file upload) in the controller instead of the
  online/cloud check.
- Login is **HTTPS on 8043**. `8843` is the guest portal (404 on `/login`).

---
_Tested on: `debian` (Debian 13 Trixie, Podman 5.4.2), 2026-06-29 — fresh
install (no Docker data to migrate), pinned to `6.2.10.17`, completed the
first-run setup wizard, restored an in-app `.cfg` backup successfully, and
confirmed firmware upgrade works via Local Upgrade after the cloud-check
network issue above._
