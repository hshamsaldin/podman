# Host setup (one-time, per machine)

Do this once on a fresh host before deploying any container from this repo.
Target: **rootless Podman + Quadlet** on Debian / Raspberry Pi OS.

Automates as [`scripts/podman.sh`](../scripts/podman.sh) — covers steps 1-4 and 6
below interactively (run it, or follow the manual steps yourself). Step 5
(shared proxy network) is prompted inside the script; step 7 (Docker data
migration) is per-container and not automated.

_Verified on: `debian` (Debian 13 Trixie, Podman 5.4.2), 2026-06-29 — every
step below ran successfully via `scripts/podman.sh`._


## 1. Install Podman (need ≥ 4.4 for Quadlet)

Quadlet — the `.container` → systemd generator this whole repo depends on — was
added in **Podman 4.4**. Check what your distro ships **before** anything else:

```bash
apt-cache policy podman      # candidate version
podman --version             # if already installed
```

- **Debian 13 "Trixie" / recent Raspberry Pi OS** ship Podman **5.x** — just:
  ```bash
  sudo apt update
  sudo apt install -y podman
  ```
- **Raspberry Pi OS / Debian 12 "Bookworm"** ship Podman **4.3.1 — NO Quadlet.**
  You must get a newer Podman. Options, in order of preference:
  1. Upgrade the OS to Trixie (gets 5.x from the normal repo), or
  2. Install from `bookworm-backports` if a backport is available:
     ```bash
     echo 'deb http://deb.debian.org/debian bookworm-backports main' |
       sudo tee /etc/apt/sources.list.d/backports.list
     sudo apt update
     sudo apt -t bookworm-backports install -y podman
     podman --version          # confirm ≥ 4.4 (ideally ≥ 5.0)
     ```

> Why ≥ 4.4 specifically: `AutoUpdate=` (upgrades) and `Network=container:` (the
> qBittorrent↔gluetun kill switch) also require it. ≥ 5.0 is recommended.

Install the rootless dependencies if not already present:
```bash
sudo apt install -y uidmap slirp4netns fuse-overlayfs
```

## 2. Rootless user namespaces (subuid / subgid)

Rootless Podman maps container UIDs into a sub-range owned by your user. Most
distros pre-populate this; confirm you have a range, and add one if missing:

```bash
grep "^$USER:" /etc/subuid /etc/subgid      # expect e.g. hussein:100000:65536
# if EITHER file has no line for you:
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate                        # apply the new mapping
```

### Finding a container's REAL host UID (no `UserNS=` set)

A container with no `UserNS=` line uses Podman's default rootless mapping:
container UID `0` → your real UID; container UID `1..65535` → your `/etc/subuid`
range, contiguous from its start. So container UID `N` (`N ≥ 1`) is always:

```
host_uid = subuid_start + (N - 1)
```

You need this whenever a container with no `UserNS=` (e.g. one riding a pod
that can't use `keep-id` — see [gluetun](../containers/gluetun)) must read/write
a bind-mounted path that already has real files on it. Don't hardcode the
result anywhere — it's host-specific (depends on your `/etc/subuid` range).
Compute it on whichever host you're deploying to:

```bash
./scripts/derive-rootless-uid.sh <container-uid>     # e.g. 1000 for PUID=1000
```

Then apply it to the path that needs it:
- **Native filesystem** (ext4/xfs/btrfs): `sudo chown -R <result>:<result> <path>`.
- **Foreign filesystem** (NTFS/exFAT via `ntfs-3g`/`exfat`): these fake Unix
  ownership entirely from the mount's `uid=`/`gid=` option in `/etc/fstab` —
  `chown` is a silent no-op on them, real per-file ownership doesn't exist.
  Set that mount option to `<result>` instead (see
  [jellyfin's fstab steps](../containers/jellyfin) for the mount itself; if
  another container on the *same* disk needs your real UID instead — e.g.
  Jellyfin reading the same media read-only via `keep-id` — the mount can only
  satisfy one fixed owner, so give the **writer** the owner slot and rely on
  the mount's `umask` granting the **reader** "other" read access instead of
  loosening anything further).

## 3. Start user services at boot — enable linger (CRITICAL)

Rootless containers run as **user** systemd services. Without "linger" they only
run while you are logged in and **stop on logout / never start at boot** — fatal
for a headless Pi. Enable it once:

```bash
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" | grep Linger     # Linger=yes
```

Make the Quadlet directory and prime the user systemd generator:

```bash
mkdir -p ~/.config/containers/systemd
systemctl --user daemon-reload
```

## 4. Host knobs some containers need

- **`/dev/net/tun`** (netbird, gluetun) — must exist and be readable by your user.
  It is standard on Linux: `ls -l /dev/net/tun`; if missing, `sudo modprobe tun`.
- **Unprivileged ports** — rootless can bind **≥ 1024** with no extra setup; every
  container here uses high ports, so nothing to change.
- **`avahi-daemon` + host `dbus`** (atvloadly only) — see that container's README;
  rootless access to the host sockets has its own caveats documented there.

## 5. Shared proxy network (optional)

Only needed if you run containers behind a reverse proxy (see the standard, §5).
Create it once as a Quadlet `.network` unit:

```bash
cat > ~/.config/containers/systemd/proxy.network <<'EOF'
[Network]
NetworkName=proxy
EOF
systemctl --user daemon-reload
```
Containers then reference `Network=proxy.network`.

## 6. Pick a stacks root

Unit files and app data live in fixed rootless locations — keep them consistent:

| What | Where |
|------|-------|
| Quadlet unit files | `~/.config/containers/systemd/` |
| App data + `.env`  | `~/containers/<app>/` |

```bash
mkdir -p ~/containers
```

Each container then has its `.container` unit in the systemd dir and its data
under `~/containers/<app>/`.

## 7. Migrating data from the Docker setup

Podman does **not** see Docker's named volumes. For containers whose state lived
in a Docker volume (NetBird registration, Omada controller DB), either re-set-up
fresh or migrate the bytes — see each container's README (`## Notes` / `## Backup`)
for the exact, per-app migration. Bind-mounted data (atvloadly `/etc/atvloadly`,
jellyfin/qbittorrent `./config`) just needs the rootless ownership check in §2.
