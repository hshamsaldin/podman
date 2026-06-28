<!--
CONTAINER README TEMPLATE — copy this to containers/<app>/README.md and fill in.
Keep the section order below for EVERY container. Delete sections only if truly
N/A (e.g. "Backup" for a stateless app) and say why. Keep it short; link out
for deep guides instead of pasting walls of text.
-->
# <Name>

<One-sentence description of what it does.>

|              |                                          |
|--------------|------------------------------------------|
| **Upstream** | [vendor/project](https://github.com/vendor/project) |
| **Image**    | `docker.io/vendor/image:tag`             |
| **Web UI**   | `http://<host>:PORT` (or `—`)            |
| **Storage**  | `<source>` → `<container path>`          |
| **Network**  | `<app>.network` (default) / `host` / `container:<other>` |
| **Host deps**| `<e.g. avahi, dbus, /dev/net/tun>` (or `—`) |

## Prerequisites

<Host packages, shared networks, setup keys — or "None." Link to
[host setup](../../docs/host-setup.md) for Podman/rootless itself.>

## Deploy

> ⚠️ UNTESTED on the host — verify before trusting.

```bash
mkdir -p ~/containers/<app>
cp .env.example ~/containers/<app>/.env      # then edit it
cp <app>.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start <app>
```

## Upgrade

```bash
podman auto-update                            # pulls + restarts if image changed
```

## Verify

```bash
systemctl --user status <app>
podman ps
# + the app's own health/status check
```

## Backup

<How to back up the persistent data — or "None — stateless.">

## Notes

- <Any deliberate deviation from the repo standard, and why.>
- <Rootless gotchas (UID mapping, host sockets), links to deeper docs.>

---
_⚠️ UNTESTED on this host — Quadlet translation of the tested Docker stack._
_Replace with: `Tested on: <host>, <YYYY-MM-DD>` once Deploy + Upgrade have run._
