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
`.pod`.** A container that joins another container's netns directly cannot
also set up its own user namespace — rootless Podman fails the start with
`status=126` and never creates the container (symptom: the unit's own
`systemctl --user status` line already shows `status=126` before the app logs
anything). The tempting quick fix is to drop `keep-id` and let the image's own
PUID/PGID logic handle ownership — **don't**: without `keep-id`, the
container's "UID 1000" maps to the rootless subuid offset (e.g. host UID
`100999`), not your real UID `1000`, so it can no longer read/write any
*pre-existing* bind-mounted files (confirmed live: a fully-downloaded torrent
went "Errored" with "Permission denied" on every file). Give the namespace its
own Quadlet **`.pod`** instead, with every member container joining via
`Pod=<name>.pod` (no `Network=`/`PublishPort=` of its own).

**But check every pod member before adding `UserNS=keep-id` to the pod — a
container that manages its own iptables/nftables (a VPN client, a firewall)
can refuse to start under it, and there's no per-member exception (verified,
two ways, no workaround found).** We tried exactly this for a VPN+downloader
pod:
1. **`keep-id` on the pod** (so every member shares it): fixed the
   downloader's file-ownership problem above, but the VPN container then
   failed outright — `ERROR creating iptables firewall: ... Permission denied
   (you must be root)` on every iptables backend, container exits immediately.
   Checked the VPN app's own source/docs directly: **no documented way to
   disable its internal firewall** exists to work around this.
2. **`keep-id` on just the downloader** (still joined to the pod via `Pod=`,
   not a direct netns join — hoping pod membership wouldn't force a shared
   userns the way a direct join does): rejected identically to the original
   direct-join conflict (`status=126`, container never created). Matches open
   upstream bugs
   [containers/podman#26889](https://github.com/containers/podman/issues/26889),
   [#22931](https://github.com/containers/podman/issues/22931) — Quadlet's
   handling of per-container `UserNS=` inside a pod is currently unreliable.

This is not a missing capability or a config mistake: the kernel's nft "rule
set generation id" check only trusts a single contiguous UID mapping starting
at 0 (what plain default rootless mapping gives you); `keep-id` splices your
real UID into the middle of that range, producing a fragmented mapping nft
rejects, and Quadlet can't currently scope that mapping to just one pod
member either. When a pod has any member like this, drop `UserNS=` from the
pod entirely (and don't try it per-member) and fix each member's pre-existing
bind-mounted files individually instead — **derive** the real host UID, don't
guess or hardcode it:
```bash
./scripts/derive-rootless-uid.sh <container-uid>      # e.g. the image's PUID
# -> prints the real host UID for THIS host's /etc/subuid range
sudo chown -R <result>:<result> <path>                 # native filesystem
```
This is the one fact that's host-specific (the number); the formula and the
script that computes it are not — copy this repo to a fresh host and re-run
the script there, never copy a number between hosts.

**Foreign filesystems (NTFS/exFAT) need the *mount's* owner changed, not the
files (verified — `chown` is a silent no-op on them).** `ntfs-3g`/`exfat` fake
Unix ownership entirely from `/etc/fstab`'s `uid=`/`gid=` option; there's no
real per-file ownership to `chown`. If the path above is on one of these, set
that mount option to the derived UID instead, then **force a real remount**
(see the warning below — don't trust `mount`/`findmnt`'s generic FUSE options
line, it never reflects `ntfs-3g`'s internal uid/gid either way):
```bash
sudo systemctl daemon-reload
sudo systemctl stop data.mount   # use the unit name systemd generated for your mountpoint
ps aux | grep -i ntfs            # confirm the OLD mount.ntfs-3g process actually exited —
                                  # a lazy/partial unmount can leave it running, silently
                                  # serving the OLD uid/gid despite a "successful" remount
sudo systemctl start data.mount
ps aux | grep -i ntfs            # NOW confirm the new uid=/gid= appears in its command line
```

> ⚠️ **Never run `fuser -km <mountpoint>` to free a busy mount (learned the
> hard way, live, on a production host).** `-m` can resolve to "every process
> using this filesystem" far more broadly than the one stale process you're
> after — it killed core system services (`sshd`, `systemd-journald`, the
> rootless user session and every container under it) here, not just the
> intended `ntfs-3g` process. The system survived (no reboot, no data loss),
> but every running container had to be recovered afterward. To find what's
> actually holding a mount open, use the **read-only** `lsof +D <mountpoint>`
> or `fuser -v <mountpoint>` (no `-k`) first, and only kill the *specific PID*
> you've confirmed is stale (`sudo kill <pid>`), never a broad `-k` sweep.

See [gluetun's README](../containers/gluetun) and
[qbittorrent's README](../containers/qbittorrent) for the full worked example,
including how to connect a *future* container to the same shared pod.

**Recovering a rootless session after something kills its backing processes
(e.g. the `fuser -km` mistake above) — `podman system migrate` may itself
crash; don't rely on it alone (verified live).** Symptom: every `podman`
command fails with `invalid internal status, try resetting the pause process
with "podman system migrate": open /run/user/<uid>/<name>.pid: no such file
or directory`. What actually worked, in order:
```bash
# 1. podman's own suggested fix — try it, but it crashed with a SIGSEGV here
#    while tearing down a container's network. If it crashes, move on to step 2;
#    don't keep retrying it.
podman system migrate

# 2. The real culprit: the specific missing .pid file named in the error.
#    Feed it a definitely-dead PID (NOT via `echo`, which appends a newline
#    Podman's strconv.Atoi can't parse — use printf):
printf '999999' > /run/user/<uid>/<name>.pid
podman ps -a   # should now work — even if it still errors once more with
               # "could not find any running process: no such process", that's
               # PROGRESS (it parsed the file and checked liveness); it means
               # the underlying systemd services are likely already fine.
```
In practice, `systemd --user` with `Restart=always` had already silently
recovered every container in the background the whole time the CLI was
broken — the corruption only blocked `podman`'s own listing/inspection
commands, not the actual running services. Check `systemctl --user status
<service>` directly; you may find everything is already healthy once the CLI
itself stops erroring. Only reach for the more disruptive `podman system
reset` (wipes Podman's container/pod/image bookkeeping, but never touches
bind-mounted host data) if the lighter fixes above don't get `podman ps -a`
working again.

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
