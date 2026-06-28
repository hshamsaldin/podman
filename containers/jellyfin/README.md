# Jellyfin

Free Software media server — streams your movies/shows to any device.

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [jellyfin/jellyfin](https://github.com/jellyfin/jellyfin) (GPL-2.0) |
| **Image**    | `docker.io/jellyfin/jellyfin:latest`     |
| **Web UI**   | `http://<host>:8096`                      |
| **Storage**  | `~/containers/jellyfin/{config,cache}` (bind) · media disk → `/data` (bind, read-only) |
| **Network**  | `jellyfin.network` (bridge), publishes `8096` |
| **Host deps**| media disk mounted via `/etc/fstab` at `MEDIA_PATH` |

## Prerequisites

- Rootless Podman ≥ 4.4 + linger — see [host setup](../../docs/host-setup.md).
- Media disk mounted on the host at `MEDIA_PATH`. Values are **per-host** — discover
  this machine's, never copy another's:

  1. **Read the partition's UUID and filesystem type** (don't assume `ext4`):
     ```bash
     lsblk -f          # note the data partition's UUID and FSTYPE
     ```
  2. **Install the driver** if it's a foreign filesystem (native ext4/xfs/btrfs need none):
     ```bash
     sudo apt install -y ntfs-3g       # NTFS  (Windows-formatted disks)
     sudo apt install -y exfatprogs    # exFAT
     ```
  3. **Create the mount point.** We mount at `/data` so the host path matches the
     container path — same `/data` everywhere:
     ```bash
     sudo mkdir -p /data
     ```
  4. **Add one line to `/etc/fstab`**, substituting your own `UUID`, `FSTYPE`, and —
     for NTFS/exFAT — your `id -u`/`id -g`. `nofail` keeps boot from hanging if the
     disk is absent:
     ```
     # native Linux fs (ext4/xfs/btrfs):
     UUID=<uuid>  /data  <fstype>  defaults,nofail  0  2
     # foreign fs (ntfs-3g / exfat) — read-only is all Jellyfin needs:
     UUID=<uuid>  /data  ntfs-3g   ro,nofail,uid=<uid>,gid=<gid>,umask=022  0  0
     ```
  5. **Reload systemd, mount, and confirm:**
     ```bash
     sudo systemctl daemon-reload
     sudo mount -a
     ls /data          # your media should list — same path the container sees
     ```

### USB disk dropping off under load? (UAS quirk)

On a Raspberry Pi, many USB‑SATA/NVMe bridges (Realtek RTL9210, JMicron, some
ASMedia) ship **buggy UAS** (USB Attached SCSI) firmware that crashes the USB
controller under sustained I/O — exactly what a media server + downloads cause.
The drive vanishes mid-use and `/data` silently falls back to the SD card. Signs
in `dmesg`:

```
sd 0:0:0:0: [sda] ... uas_eh_abort_handler ...
xhci_hcd 0000:01:00.0: xHCI host controller not responding, assume dead
```

**Fix — force the stable `usb-storage` driver for that one bridge:**

1. Find *your* bridge's USB ID (don't copy another host's):
   ```bash
   lsusb     # e.g. "Bus 002 ... ID 0bda:9210 Realtek ... RTL9210B-CG"
   ```
2. Append `usb-storage.quirks=<vid>:<pid>:u` to the **single line** in
   `/boot/firmware/cmdline.txt` (`:u` = ignore UAS), keeping it one line:
   ```bash
   sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
   grep -q usb-storage.quirks /boot/firmware/cmdline.txt || \
     sudo sed -i 's/$/ usb-storage.quirks=<vid>:<pid>:u/' /boot/firmware/cmdline.txt   # e.g. 0bda:9210:u
   sudo reboot
   ```
3. Confirm after reboot:
   ```bash
   dmesg | grep -iE 'UAS is ignored|Quirks match|usb-storage'
   # -> "UAS is ignored for this device, using usb-storage instead"
   ```

Trade-off: slightly lower sequential throughput (no command queuing), but
rock-solid — still well above the Pi's 1 GbE bottleneck. Also fixes the same disk
for [qbittorrent](../qbittorrent) on `/data`.

## Deploy

> ⚠️ UNTESTED on the host — verify before trusting.

```bash
mkdir -p ~/containers/jellyfin
cp .env.example ~/containers/jellyfin/.env       # then edit PUID/PGID/TZ/MEDIA_PATH
cp jellyfin.container jellyfin.network ~/.config/containers/systemd/

# config/cache must be owned by your host user (rootless + UserNS=keep-id maps
# your UID 1:1, so files you create are usable inside the container):
mkdir -p ~/containers/jellyfin/config ~/containers/jellyfin/cache

# IMPORTANT: mirror .env into the unit — Quadlet does NOT interpolate .env into
# directives. In jellyfin.container set:
#   User=<your id -u>:<your id -g>     (default 1000:1000)
#   Volume=<MEDIA_PATH>:/data:ro       (default /data:/data:ro)

systemctl --user daemon-reload
systemctl --user start jellyfin
```

Open `http://<host>:8096`, run the setup wizard, and point libraries at
`/data` (e.g. `/data/Movies`, `/data/Shows`).

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

## Verify

```bash
systemctl --user status jellyfin              # active (running)
podman logs -f Jellyfin                       # watch for startup errors
# then load the Web UI and confirm a library scan finds your media
```

## Backup

```bash
# bind mount — just tar the config (media is not backed up here):
tar czf jellyfin-$(date +%F).tar.gz -C ~/containers/jellyfin/config .
```

## Subtitle tooling

`scripts/ManageSubtitles.sh` attaches external subtitle files to episodes so
Jellyfin auto-detects them. Run it on the **host** with **no arguments** — it lists
your shows (pick by number), lists that show's seasons, asks for the subtitles and
language, previews the mapping, and on `y` copies each sub **beside its episode**
as `<video-basename>.<lang>.srt`, archives a copy in `Subtitles/`, flattens any
`Season NN/Season NN`, and can trigger a Jellyfin library scan. Needs `python3` + `curl`.

It is host-side and runtime-agnostic (talks to the Jellyfin HTTP API), so it is
unchanged from the Docker setup — it just reads the **same `.env`** as the unit.

Install once — keep the script under your jellyfin data dir so it reads the same `.env`:
```bash
cp -r scripts ~/containers/jellyfin/                   # -> ~/containers/jellyfin/scripts/
chmod +x ~/containers/jellyfin/scripts/ManageSubtitles.sh
# optional: run it from anywhere (the symlink is resolved, still finds ../.env)
sudo ln -sf ~/containers/jellyfin/scripts/ManageSubtitles.sh /usr/local/bin/ManageSubtitles.sh
```

Then run it — no options:
```bash
~/containers/jellyfin/scripts/ManageSubtitles.sh      # or just: ManageSubtitles.sh  (if symlinked)
```

Shows resolve under `$JELLYFIN_SHOWS` (default `/data/jellyfin/Shows`); the scan
hits `$JELLYFIN_URL` (default `http://localhost:8096`). Matches
`.srt .ass .ssa .vtt .sub`, language defaults to `ara` (3-letter ISO 639-2). Only
seasons present in the subtitle source are touched. Put `JELLYFIN_API_KEY` in your
`~/containers/jellyfin/.env` to skip the auto-scan prompt.

## Notes

- **Deviation — `/data` is the media disk, not `./data`.** Container `/data` is the
  external media disk (`MEDIA_PATH`, read-only). Jellyfin's writable data lives in
  `./config` + `./cache` (binds under `~/containers/jellyfin/`).
- **Rootless UID mapping (Podman-specific).** `UserNS=keep-id` + `User=1000:1000`
  map your host UID 1:1 into the container so the bind-mounted `config`/`cache`
  (and the read-only media) stay owned by, and readable as, your user. **`User=`
  must equal your real `id -u`:`id -g`** — Quadlet can't read it from `.env`, so
  set it literally. If Jellyfin crash-loops on `Access to the path '/config/log'
  is denied`, the UID mapping (or `config` ownership) is the cause.
- **Deviation — `--memory=2g`** (above the 512m baseline), via `PodmanArgs`. Pi 4B
  with 3.7 GiB RAM. **Caveat:** Raspberry Pi OS ships with the memory cgroup
  disabled, so the limit is silently discarded until you append
  `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` and reboot.
- **Deviation — no `ReadOnly` rootfs.** Not verified safe for this image, so left off.
- **`/data` is read-only** — Jellyfin never writes to your media. If you later use
  features that write back (e.g. `.nfo` metadata), drop `:ro` on that Volume.
- **Reverse proxy:** change `PublishPort=8096:8096` to `127.0.0.1:8096:8096` and
  join the shared `proxy.network` instead.
- **Hardware transcoding is not configured** (ARM Pi, no VAAPI). Software
  transcoding works as-is.

---
_⚠️ UNTESTED on this host — Quadlet translation of the tested Docker stack
([docker repo](https://github.com/hshamsaldin/docker/tree/main/containers/jellyfin)).
The host-side fstab/UAS-quirk and `ManageSubtitles.sh` steps are runtime-agnostic
and carry over verified; the rootless Podman deploy (UID mapping, mem cgroup)
needs host verification. Replace with `Tested on: <host>, <YYYY-MM-DD>` once run._
