# Podman

One place for every Podman container I run, with a single standard for how each
one is organized, stored, secured, and upgraded. **Rootless Podman + Quadlet
(systemd) units** — no daemon, no `docker run`, no snowflakes.

This is the Podman port of my [docker](https://github.com/hshamsaldin/docker)
repo: same containers, same rules, re-expressed as native Podman.

New host? Start with [docs/host-setup.md](docs/host-setup.md), then deploy any
container below. Coming **from Docker**? Follow
[docs/migration.md](docs/migration.md) — a one-container-at-a-time cutover with
Docker kept as instant rollback.

> ## ⚠️ Only tested commands
> Nothing goes into this repo until it has been **run on the real host and worked**.
> No guessing, no "should work." Anything not yet verified is marked `⚠️ UNTESTED`.
> Each container README ends with a **Tested on** line recording the host + date
> its commands were last verified.
>
> ### Conversion status: 4/5 verified live on the host
> jellyfin, gluetun+qbittorrent, netbird, and atvloadly are migrated and
> verified on `raspberrypi` (real `Tested on:` lines in each README) — every
> one of them needed at least one real fix the Docker stack never surfaced
> (capabilities, UID mapping, firewall interactions); see each README's Notes
> and [docs/migration.md](docs/migration.md) for what was actually wrong and
> how it was found. **omada is still `⚠️ UNTESTED`** — treat its
> Deploy/Upgrade as "convert + verify," not "copy + trust," same as the rest
> were until proven.

## Why Quadlet (and not `podman compose`)

Quadlet is Podman's **current, recommended** way to run containers under systemd
(built in since Podman 4.4). It replaces the older, now-deprecated
`podman generate systemd`. Each container is described by a `.container` file;
Podman's systemd generator turns it into a real `<name>.service` you manage with
`systemctl --user`. Reboot-persistence, ordering, restart, and health all come
from systemd — exactly what `restart: unless-stopped` approximated under Docker.

`podman compose` / `podman-compose` exist, but they re-interpret Compose files
with known rough edges (notably `network_mode: service:` and `depends_on`
conditions — both used by the qBittorrent stack). Quadlet is the native path, so
that is what this repo standardizes on.

> **Requires Podman ≥ 4.4** (Quadlet). `AutoUpdate=` and `Network=container:`
> also need ≥ 4.4. Raspberry Pi OS *Bookworm* ships Podman **4.3.1 (no Quadlet)** —
> see [host setup](docs/host-setup.md) for getting a new enough Podman.

## Containers

| Container | Purpose | Image | Port | Storage |
|-----------|---------|-------|------|---------|
| [netbird](containers/netbird) | WireGuard mesh VPN client | `docker.io/netbirdio/netbird:latest` | — | `netbird-client` (volume) |
| [atvloadly](containers/atvloadly) | Apple TV IPA sideloading | `docker.io/bitxeno/atvloadly:latest` | 5533 | `/etc/atvloadly` (bind) |
| [omada](containers/omada) | TP-Link Omada SDN controller ⚠️ UNTESTED | `docker.io/mbentley/omada-controller:latest` | 8043 | `omada-data` / `omada-logs` (volume) |
| [jellyfin](containers/jellyfin) | Media server | `docker.io/jellyfin/jellyfin:latest` | 8096 | `./config`, `./cache` (bind) |
| [gluetun](containers/gluetun) | Shared ProtonVPN pod — other containers ride it | `docker.io/qmcgaw/gluetun:latest` | — (members publish theirs) | `./state` (bind) |
| [qbittorrent](containers/qbittorrent) | Torrent client, rides the gluetun pod | `lscr.io/linuxserver/qbittorrent:latest` | 8080 | `./config` (bind) |

> Keep this table updated whenever you add or remove a container.
> Images are **fully qualified** (`docker.io/...`) — Podman has no implicit
> Docker Hub default, and `AutoUpdate=registry` requires a fully-qualified name.

## Adding a new container

1. `cp -r templates containers/<app>` — gives you `app.container`, `app.network`,
   `.env.example`, `README.md`.
2. Rename `app.container` → `<app>.container`; fill in `Image=` (fully qualified,
   `:latest`), `ContainerName=`, `HostName=`, storage, network.
3. Fill in the README from the template — **keep the section order** (see Style).
4. Add only the `AddCapability=` / `AddDevice=` the app genuinely needs.
5. Secrets go in `.env` (copy from `.env.example`); confirm `.env` is gitignored,
   and point the unit at it with `EnvironmentFile=`.
6. Install + start (see §1), then check `systemctl --user status <app>` +
   `podman ps` + the app's health.
7. Add a row to the **Containers** table above.
8. Commit the folder (units + README + `.env.example`) — never `.env` or `data/`.

## README style (every container README)

Each `containers/<app>/README.md` is a copy of [templates/README.md](templates/README.md)
and uses this **fixed structure**:

1. `# <Name>` + one-sentence description
2. **At-a-glance table**: Upstream · Image · Web UI · Storage · Network · Host deps
   (always credit/link the original upstream project)
3. `## Prerequisites` → `## Deploy` → `## Upgrade` → `## Verify` → `## Backup` → `## Notes`

Rules: keep it short, link out to deeper docs instead of pasting walls of text,
and record any deliberate deviation from this standard under `## Notes`.

---

## 1. One container = one Quadlet unit = one systemd service

- Every app is a `containers/<app>/<app>.container` file (plus a `.network` if it
  needs its own bridge). An app that shares a netns with others (e.g. qBittorrent
  riding [gluetun](containers/gluetun)) lives in its own folder and joins the
  owner's `.pod` via `Pod=<name>.pod` instead of declaring its own network.
- Folder name = app name = lowercase (`netbird`, `atvloadly`).
- **No `podman run`** for anything permanent. If it should survive a reboot, it is
  a Quadlet unit — systemd owns its lifecycle.
- Unit files install to **`~/.config/containers/systemd/`** (rootless). App data
  and `.env` live under **`~/containers/<app>/`**.

**Install / start / stop a unit** (Quadlet generates `<app>.service` from
`<app>.container` — you never write the `.service` by hand, and you do **not**
`systemctl enable` it; boot-start comes from `[Install] WantedBy=default.target`):

```bash
cp containers/<app>/<app>.container ~/.config/containers/systemd/
systemctl --user daemon-reload          # regenerate services from Quadlet units
systemctl --user start <app>            # start now
systemctl --user status <app>           # check
systemctl --user stop <app>             # stop
```

## 2. Naming — be explicit, never rely on defaults

| Thing            | Rule                                        | Example                          |
|------------------|---------------------------------------------|----------------------------------|
| Folder           | lowercase app name                          | `containers/netbird`             |
| Unit file        | `<app>.container`                           | `netbird.container`              |
| `ContainerName=` | = app name (without it, Podman uses `systemd-<unit>`) | `NetBird`              |
| Named volume     | `<app>-<purpose>` via a `.volume` unit      | `netbird-client`                 |
| Network          | `<app>.network` → real net `systemd-<app>`  | `jellyfin.network`               |
| Image            | fully qualified, `:latest`; auto-update     | `docker.io/netbirdio/netbird:latest` |

## 3. Storage — data is never inside the container

Two allowed patterns. Pick one per container and document it.

**A. Bind mount (default — clear path, easy backup):**
```ini
[Container]
Volume=%h/containers/<app>/data:/var/lib/app
```
`%h` is the systemd specifier for the user's home, so the unit is host-agnostic.
Everything is visible at `~/containers/<app>/data` and trivially backed up with `tar`.

**B. Named volume (when the app is picky about permissions/UID):**
Declare it in a `.volume` unit (or mark it external) and reference it:
```ini
[Container]
Volume=netbird-client.volume:/var/lib/netbird
```

Rules:
- New containers default to **bind mounts** (pattern A) for visibility + backup.
- **Rootless caveat:** a bind-mount file owned by host UID 1000 is **not** UID 1000
  inside the container — rootless Podman shifts UIDs into your subuid range. Use
  `UserNS=keep-id` so your host UID maps 1:1 into the container (then `PUID/PGID`
  or `User=` match your real `id -u`/`id -g`). Jellyfin pins it directly. **Not
  every container can**, though: [gluetun](containers/gluetun)'s pod runs with
  **no** `UserNS=` at all, on any member — its VPN kill-switch (nftables)
  hard-fails under `keep-id`'s fragmented UID mapping, with no documented way
  to disable it, and per-container `keep-id` on a single pod member fails the
  same way (verified live both ways, see that container's Notes). When a
  container's own requirement conflicts with `keep-id`, it loses the 1:1
  mapping — **derive** its real host UID (`docs/host-setup.md` → "Finding a
  container's REAL host UID", a formula + script, never a hardcoded number)
  and fix pre-existing bind-mounted files with `sudo chown -R <derived>:<derived>
  <path>` (native filesystem) or the mount's `uid=`/`gid=` option (NTFS/exFAT —
  `chown` is a no-op there; see [qbittorrent](containers/qbittorrent)'s Notes
  for the worked example). Don't use `podman unshare chown` for this — its
  translation can mismatch a specific pod member's actual resolved UID
  (confirmed live).
- **Docker volumes do NOT carry over.** Podman has its own volume store; a
  container that used an external *Docker* volume (NetBird, Omada) needs its data
  migrated (see those READMEs) or a fresh setup. There is no shared volume namespace.
- **Never** write data to a path that isn't a mount. Anything not on a mount is
  lost on upgrade — by design.

## 4. Security baseline (apply to every container)

```ini
[Container]
NoNewPrivileges=true          # block privilege escalation
DropCapability=ALL            # drop everything…
AddCapability=NET_ADMIN       # …then add back ONLY what's needed
# ReadOnly=true               # if the app tolerates it; add Tmpfs=/tmp

[Service]
Restart=always                # systemd is the supervisor (≈ unless-stopped)
```

Resource caps go through `PodmanArgs=` (the dedicated `Memory=` / `PidsLimit=`
keys need a newer Quadlet than Podman 5.4.2 ships — verified unsupported on the host):
```ini
[Container]
PodmanArgs=--memory=512m --pids-limit=200
```

More rules:
- **Always pull latest.** Use `:latest` + `AutoUpdate=registry`, and upgrade with
  `podman auto-update` (see §6). Trade-off: no clean version rollback — to revert,
  pin a known-good tag/digest temporarily, then go back to `:latest`.
- **Least capability.** Start from `DropCapability=ALL`, add only what the app needs.
- **Bind ports to localhost** behind a reverse proxy:
  `PublishPort=127.0.0.1:5533:80` — not reachable from the LAN directly.
- **Rootless ports:** unprivileged users can bind **≥ 1024** out of the box. All
  containers here publish high ports, so no extra config is needed. (For < 1024,
  lower `net.ipv4.ip_unprivileged_port_start` — none of these need it.)
- **Secrets live in `.env`**, never in the unit, never committed. Reference with
  `EnvironmentFile=`. Commit `.env.example` only.
- **Run as non-root** where the image supports it: `User=` or `PUID/PGID` +
  `UserNS=keep-id`.

## 5. Networks

- Each container gets its **own** bridge via a `<app>.network` unit (Quadlet
  prefixes the real network `systemd-<app>` for isolation by default).
- Apps that must talk to a reverse proxy join a **shared** network — create one
  `proxy.network` unit and reference `Network=proxy.network` from each.
- Only publish ports you actually need; everything internal stays on the bridge.
- **Shared netns for multiple containers — use a `.pod`, not `Network=container:`.**
  Joining another container's netns directly (`Network=container:<other>`)
  conflicts with `UserNS=keep-id` on the joining container — rootless Podman
  rejects the combination (verified: `status=126`, container never created).
  Give the namespace its own `.pod` unit instead, with every member container
  joining via `Pod=<name>.pod` (no `Network=`/`PublishPort=` of its own — the
  pod owns those). **`UserNS=keep-id` is not automatically safe, at any
  level.** Tried three ways with [gluetun](containers/gluetun) before giving
  up on it entirely: pod-level `keep-id` broke gluetun's own nftables
  kill-switch (no documented way to disable it); per-container `keep-id` on
  just the riding container, still joined via `Pod=`, was rejected identically
  to the direct-join case (`status=126` — matches open upstream bugs
  [containers/podman#26889](https://github.com/containers/podman/issues/26889),
  [#22931](https://github.com/containers/podman/issues/22931)). If any pod
  member manages its own iptables/nftables, assume `keep-id` is off the table
  for the **whole pod**, no exceptions, until those bugs are fixed upstream.
  Members that lose their 1:1 UID mapping as a result: **derive** the real
  host UID (`docs/host-setup.md`'s formula/script — never hardcode it) and
  apply it directly to pre-existing bind-mounted paths (`chown` on a native
  filesystem; the mount's `uid=`/`gid=` option for NTFS/exFAT — see
  [qbittorrent](containers/qbittorrent)'s Notes for the worked example).
  Connecting a *future* container to an existing shared pod: add
  `Pod=<name>.pod` + `Requires=`/`After=<owner>.service` to the new unit, and
  add its port to the pod's `PublishPort=` list.

## 6. Upgrades — `podman auto-update`

Every unit carries `AutoUpdate=registry`, so one command pulls newer images for
all of them and restarts only the units whose image actually changed:

```bash
podman auto-update                       # pull + restart changed units
podman auto-update --dry-run             # preview what would change
```
- Volumes are never touched.
- Images use `:latest`, so `auto-update` always compares against the newest build.
- Verify after: `systemctl --user status <app>` + the app's own status/health check.
- Reclaim space occasionally: `podman image prune` (safe — never removes volumes).
- Update everything + prune in one go: [`scripts/update-all.sh`](scripts/update-all.sh).

## 7. Backup before risky changes

```bash
# named volume:
podman volume export <vol> -o <app>-$(date +%F).tar
# (or, portably:)
podman run --rm -v <vol>:/data:ro -v "$PWD":/backup docker.io/library/alpine \
  tar czf /backup/<app>-$(date +%F).tar.gz -C /data .

# bind mount:
tar czf <app>-$(date +%F).tar.gz -C ~/containers/<app>/data .
```

## Repo layout

```
podman/
├── README.md                  # this file — the standard + container index
├── .gitignore                 # never commit secrets/data
├── docs/
│   ├── host-setup.md          # one-time host prep (Podman, rootless, linger)
│   └── migration.md           # Docker -> Podman, one container at a time
├── templates/                 # copy these to start a new container
│   ├── app.container
│   ├── app.network
│   ├── .env.example
│   └── README.md
├── containers/                # one folder per app
│   ├── netbird/
│   ├── atvloadly/
│   ├── omada/
│   ├── jellyfin/
│   ├── gluetun/                # shared ProtonVPN pod — other containers ride it
│   └── qbittorrent/             # joins gluetun.pod (Pod=gluetun.pod)
└── scripts/
    ├── update-all.sh            # podman auto-update + prune
    ├── measure-footprint.sh     # snapshot RAM/disk: Docker (before) vs Podman (after)
    └── derive-rootless-uid.sh   # compute a container's real host UID (no UserNS= set)
```

## Measuring the switch (Docker → Podman footprint)

The whole point of going daemonless: Docker keeps `dockerd` + `containerd` +
a shim per container resident at all times; rootless Podman has **no daemon** —
just a tiny `conmon`/`pasta` per running container. To quantify it on your host,
snapshot before and after with [`scripts/measure-footprint.sh`](scripts/measure-footprint.sh):

```bash
# 1. while Docker is still the engine:
./scripts/measure-footprint.sh docker-before
# 2. after migrating + starting the Podman units (Docker stopped):
./scripts/measure-footprint.sh podman-after
# 3. compare:
diff footprint-docker-before-*.txt footprint-podman-after-*.txt
```
The "engine overhead" line is the headline — the resident runtime RAM you reclaim.
