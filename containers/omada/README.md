# Omada

TP-Link Omada SDN controller — manages the EAP APs, switches, and gateway. It is
a **control plane only**: APs/switches keep forwarding and the internet stays up
even while this container is stopped.

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [mbentley/docker-omada-controller](https://github.com/mbentley/docker-omada-controller) |
| **Image**    | `docker.io/mbentley/omada-controller:latest` |
| **Web UI**   | `https://<host>:8043` (self-signed cert) |
| **Storage**  | `omada-data` / `omada-logs` (named volumes) → `/opt/tplink/EAPController/{data,logs}` |
| **Network**  | published LAN-wide (devices must reach the ports) |
| **Host deps**| `—`                                      |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
- The `omada-data` / `omada-logs` volumes. A **blank** `omada-data` comes up as a
  brand-new, empty controller — migrate the old controller's data in first
  (see Notes) or you lose all sites/devices.

## Deploy

> ⚠️ UNTESTED on the host — and a major-version jump + data migration (see below).

```bash
cp omada.container omada-data.volume omada-logs.volume ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start omada
```

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

> ⚠️ UNTESTED + **major-version jump.** The Docker host ran **5.13.30**; `:latest`
> is now **6.x**. Do **not** leap 5.13 → 6.x in one pull — step through a late `5.x`
> tag first, let the DB migration finish, then go to `:latest`. Back up the volume
> (below) before each step; a migrated DB cannot be downgraded in place.

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

> ⚠️ UNTESTED.

## Notes

- **Migrating the controller off Docker (REQUIRED — do this before first start).**
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
  when crossing the 5.x → 6.x version boundary — it's the version-safe path.
  ⚠️ UNTESTED.
- **Named volumes:** recreating the container reuses the controller state. Never
  delete `omada-data`, or you lose all sites/devices.
- **PUID/PGID 508 are host-specific** (the Docker host's omada data-owner). Adjust
  to your host, or set them to whatever owns the migrated `omada-data` contents.
- **Security-baseline deviations** (deliberate): `DropCapability`, `ReadOnly`,
  `NoNewPrivileges`, and a memory cap are intentionally **omitted** — the
  controller runs MongoDB + a JVM and tightening caps against this image is
  unverified. Mirrors mbentley's proven upstream config.
- **Ports are LAN-wide.** APs/switches/gateway adopt and inform over
  `8043`/`29810-29817`/etc., so they cannot sit behind a localhost-only bind.
- **Rootless source-IP caveat:** rootless port publishing can rewrite the source
  IP of inbound device traffic (slirp4netns more so than pasta). If adoption or
  inform behaves oddly, this is the first thing to check — Podman ≥ 5 with `pasta`
  preserves source IPs better. ⚠️ verify on the host.
- Login is **HTTPS on 8043**. `8843` is the guest portal (404 on `/login`).

---
_⚠️ UNTESTED on this host — Quadlet translation of the (already UNTESTED) Docker
stack ([docker repo](https://github.com/hshamsaldin/docker/tree/main/containers/omada)).
Deploy, the major-version upgrade, and the volume migration are all unverified.
Replace with `Tested on: <host>, <YYYY-MM-DD>` once they have actually run._
