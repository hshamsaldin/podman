# Host setup (one-time, per machine)

Do this once on a fresh host before deploying any container from this repo.
Target: **rootless Podman + Quadlet** on Debian / Raspberry Pi OS.

> ⚠️ UNTESTED on this host — the steps below are the standard rootless-Podman
> bring-up, not yet run on the Pi. Verify each one and replace this note once done.

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
