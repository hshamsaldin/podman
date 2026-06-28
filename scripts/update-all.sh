#!/usr/bin/env bash
# Pull newer images and restart every Quadlet unit whose image changed, then
# prune dangling images. Volumes are never touched. Relies on every .container
# carrying `AutoUpdate=registry`.
set -euo pipefail

echo "==> Checking for updates (dry run)"
podman auto-update --dry-run || true

echo "==> Applying updates (restarts only changed units)"
podman auto-update

echo "==> Pruning dangling images"
podman image prune -f

echo "==> Done."
