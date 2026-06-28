# Migrating Docker → Podman, one container at a time

The safe way to switch: **Docker and Podman coexist**, and you cut over **one
service at a time**, verifying each on Podman *before* you give up its Docker
counterpart. Docker stays installed the whole time as an instant rollback. You
only decommission Docker once every service is proven on Podman.

> ⚠️ UNTESTED on the host — this is the intended procedure, not yet run end-to-end
> on the Pi. Verify each step; the per-container `## Verify` sections are the gate.

## Why one at a time (the golden rule)

Docker and rootless Podman **cannot publish the same host port at the same time**
(8096, 8080, 5533, 8043…). So the cutover for each service is always:
**stop the Docker container → start the Podman unit → verify → next.** Never run
both copies of one service at once.

## Once per host (before the first container)

Do the [host setup](host-setup.md) first — Podman ≥ 4.4 (you have 5.4.2 ✓),
`loginctl enable-linger`, subuid/subgid, and:

```bash
mkdir -p ~/.config/containers/systemd ~/containers
git clone https://github.com/hshamsaldin/podman.git ~/podman-repo   # the units live here
```

## The loop — repeat for each container

Notation: `<app>` = folder name (`jellyfin`), `<unit>` = `<app>.container`,
`<docker-name>` = the running Docker container name (`Jellyfin`, `qBittorrent`,
`NetBird`, `Omada`, `atvloadly`, `gluetun`).

### 1. Find where the Docker container keeps its data (don't guess)

```bash
docker inspect -f '{{range .Mounts}}{{.Type}}  {{.Source}}  ->  {{.Destination}}{{println}}{{end}}' <docker-name>
```
- `bind` rows → a host path (e.g. `/home/hussein/docker/jellyfin/config`).
- `volume` rows → a Docker named volume (needs export/import, step 3).

### 2. Stage the Podman unit + config

```bash
cd ~/podman-repo/containers/<app>
mkdir -p ~/containers/<app>
cp .env.example ~/containers/<app>/.env          # then edit it (if the app has one)
cp <app>.container ~/.config/containers/systemd/  # + any .network / .volume files
```
Then **mirror the values Quadlet can't read from `.env`** into the unit (each
README's Deploy section lists them): `User=`, the media/downloads `Volume=`
source path, and `PublishPort=`.

### 3. Bring the data across

- **Bind-mount data** — point the unit's `Volume=` at the existing path, **or**
  copy it into the new standard location preserving ownership:
  ```bash
  cp -a /home/hussein/docker/<app>/config ~/containers/<app>/config
  ```
- **Docker named volume** (NetBird, Omada) — export from Docker, import to Podman
  (do this while Docker is still up):
  ```bash
  docker run --rm -v <docker-vol>:/d -v "$PWD":/b alpine tar czf /b/<app>.tgz -C /d .
  podman volume create <app>-vol
  podman run --rm -v <app>-vol:/d -v "$PWD":/b docker.io/library/alpine tar xzf /b/<app>.tgz -C /d
  ```
  (NetBird is simpler to just re-register; Omada is safest via its in-app `.cfg`
  export/import. See those READMEs.)

### 4. Free the port — stop the Docker container

```bash
docker stop <docker-name>
```
This is reversible: `docker start <docker-name>` rolls back instantly (step 7).

### 5. Pre-pull, start, and open the firewall

**Pre-pull the image first.** Podman's image store is *separate from Docker's*, so
the first start pulls the image fresh. On a Pi that can exceed systemd's 90s
start-timeout and flash a (self-recovering) "failed" — avoid it by pulling first:
```bash
podman pull <image>                # e.g. docker.io/jellyfin/jellyfin:latest
systemctl --user daemon-reload
systemctl --user reset-failed <app>.service 2>/dev/null
systemctl --user start <app>
```

**Open the firewall.** Rootless Podman does **not** bypass `ufw` the way Docker
did — Docker injected its own iptables rules, so published ports were reachable
regardless of `ufw`. Under Podman an active `ufw` blocks LAN access until you
allow the port explicitly (run `sudo` on its own line, never inside a pasted block):
```bash
sudo ufw allow <port>/tcp
```
> ⚠️ This caught us live on Jellyfin: the container was healthy and served fine on
> the Pi itself (`curl localhost:8096` → `302`), but the browser couldn't reach it
> until `sudo ufw allow 8096/tcp`. Ports per container:

| Container | `ufw allow` |
|---|---|
| jellyfin | `8096/tcp` |
| qbittorrent | `8080/tcp` |
| atvloadly | `5533/tcp` |
| omada | `8088,8043,8843/tcp` + `19810,27001,29810/udp` + `29811:29817/tcp` |
| netbird | none (no published ports) |

**`Environment=` with an unquoted space silently drops everything after it
(verified, caused a real outage).** systemd parses `Environment=VAR=val with
spaces` as *multiple* space-separated `VAR=value` assignments on one line, not
a single value — so e.g. `Environment=CMD=/bin/sh /script.sh {{ARG}}` becomes
just `CMD=/bin/sh` inside the container; the rest is silently swallowed (only
shows up via `podman exec <ctr> env`, no error anywhere). Quote the *entire*
assignment when the value has a space: `Environment="CMD=/bin/sh /script.sh {{ARG}}"`.

**`UserNS=keep-id` + `Network=container:<other>` don't mix (verified) — use a
`.pod`, don't just drop `keep-id`.** A container that joins another container's
netns directly cannot also set up its own user namespace — rootless Podman
fails the start with `status=126` and never creates the container (symptom:
the unit's own `systemctl --user status` line already shows `status=126`
before the app logs anything). The tempting quick fix is to drop `keep-id` and
let the image's own PUID/PGID logic handle ownership — **don't**: without
`keep-id`, the container's "UID 1000" maps to the rootless subuid offset (e.g.
host UID `100999`), not your real UID `1000`, so it can no longer read/write
any *pre-existing* bind-mounted files (confirmed live: a fully-downloaded
torrent went "Errored" with "Permission denied" on every file). The correct
fix is a Quadlet **`.pod`**: put `UserNS=keep-id` on the pod once, have every
member container join via `Pod=<name>.pod` (no `UserNS=`/`Network=`/
`PublishPort=` of its own), and PUID/PGID-based ownership maps to your real
host UID again for every container in the pod. See
[gluetun's README](../containers/gluetun) for the worked example, including
how to connect a *future* container to the same shared pod.

**A container that manages its own iptables/nftables (a VPN client, a
firewall) may refuse to start under `UserNS=keep-id` (verified).** The
kernel's nft "rule set generation id" check needs genuine
UID-0-owns-the-netns semantics that `keep-id`'s UID remapping doesn't satisfy.
Symptom: the app's own log shows something like `Permission denied (you must
be root)` from iptables/nftables, and the container exits immediately — this
is the app failing, not Podman/Quadlet. If the app has a documented way to
disable its *own* internal firewall management (gluetun: `FIREWALL=off`), use
it — the kill switch / isolation is still enforced structurally by the pod's
shared netns and container lifecycle, not by the app's internal rules.

### 6. Verify (the gate — don't proceed until this is green)

```bash
systemctl --user status <app>      # active (running)
podman ps                          # container is Up
podman logs <docker-name>          # no crash loop
```
Then run the container's own **`## Verify`** check from its README (e.g. the
qBittorrent VPN-leak/IP test, NetBird `status`, the Jellyfin web UI).

### 7a. Success → lock it in

Leave Docker's copy stopped. Optionally remove just that one Docker container so
it can't accidentally restart (data is safe — it's on the volume/bind):
```bash
docker rm <docker-name>            # optional; or leave it stopped as a backup
```

### 7b. Trouble → roll back in seconds

```bash
systemctl --user stop <app>
docker start <docker-name>         # back on Docker, exactly as before
```
Then fix the unit and retry. Nothing was lost — the data wasn't touched.

## Recommended order (easiest → riskiest)

| # | Container | Why this slot | Watch out for |
|---|-----------|---------------|---------------|
| 1 | **jellyfin** | simplest rootless validation (bind mounts + one port) | `UserNS=keep-id` + `User=` must equal your `id -u`:`id -g`; media `/data` path |
| 2 | **gluetun**, then **qbittorrent** | proves the shared-pod pattern + the VPN kill switch | deploy gluetun first, confirm the tunnel/exit-IP *before* starting qBittorrent; needs `/dev/net/tun`; `UserNS=keep-id` lives on `gluetun.pod`, not either container |
| 3 | **netbird** | needs `NET_ADMIN`/`tun`; volume data | likely easiest to **re-register** with a fresh setup key |
| 4 | **omada** | external-volume migration + 5.x→6.x DB jump | migrate via in-app `.cfg`; don't leap major versions in one pull |
| 5 | **atvloadly** | **last** — most likely to need rootful | USB pairing + host dbus/avahi can be awkward rootless; may run `sudo` (system Quadlet) |

Each container's full per-step detail (env keys, `User=`, gotchas, verify command)
is in its own `containers/<app>/README.md`.

## After everything is on Podman

1. **Disable Docker** (don't purge yet — keep it as rollback for a few days):
   ```bash
   sudo systemctl disable --now docker.socket docker.service
   ```
2. **Measure the win:**
   ```bash
   ~/podman-repo/scripts/measure-footprint.sh podman-after
   diff footprint-docker-before-*.txt footprint-podman-after-*.txt
   ```
3. Once you're confident (days, not minutes), reclaim disk:
   ```bash
   sudo apt purge docker-ce docker-ce-cli containerd.io docker-compose-plugin
   ```

## Optional: see it all in Cockpit

You already run Cockpit. To manage the rootless Podman containers from its web UI:
```bash
sudo apt install -y cockpit-podman
systemctl --user enable --now podman.socket      # rootless socket Cockpit reads
```
Then the **Podman containers** section appears at `https://<pi-ip>:9090`.
