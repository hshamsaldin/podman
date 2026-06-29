#!/bin/bash
# ---- podman.sh — Rootless Podman + Quadlet host setup ---- #
# Automates the manual steps in docs/host-setup.md. Verified working on a
# real host (Debian 13 Trixie, Podman 5.4.2) 2026-06-29 — see that doc for
# the full explanation behind each step.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ---- root check ---- #
[[ $EUID -eq 0 ]] && error "Run as your regular user, not root: bash podman.sh (sudo is invoked internally where needed)"

echo ""
echo "  Podman — Rootless + Quadlet Setup"
echo ""

# ---- 1. Install Podman (need >= 4.4 for Quadlet) ---- #
info "Checking Podman version..."
if command -v podman &>/dev/null; then
  info "Podman already installed ($(podman --version))."
else
  . /etc/os-release
  if [[ "${VERSION_CODENAME:-}" == "bookworm" ]]; then
    warn "Debian 12 'Bookworm' ships Podman 4.3.1 — no Quadlet. Installing from bookworm-backports..."
    echo 'deb http://deb.debian.org/debian bookworm-backports main' | \
      sudo tee /etc/apt/sources.list.d/backports.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get -t bookworm-backports install -y podman
  else
    info "Installing Podman..."
    sudo apt-get update -qq
    sudo apt-get install -y podman
  fi
  info "Podman installed: $(podman --version)"
fi

PODMAN_MAJOR=$(podman --version | grep -oP '\d+' | head -1)
if [[ "$PODMAN_MAJOR" -lt 4 ]]; then
  error "Podman version too old for Quadlet (need >= 4.4). Upgrade the OS or use backports."
fi

info "Installing rootless dependencies..."
sudo apt-get install -y -qq uidmap slirp4netns passt fuse-overlayfs

# ---- 2. Rootless user namespaces (subuid / subgid) ---- #
info "Checking subuid/subgid range for ${USER}..."
if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null || ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
  warn "No subuid/subgid range found for ${USER}, adding one..."
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER}"
  podman system migrate
  info "subuid/subgid range added and applied."
else
  info "subuid/subgid range already present:"
  grep "^${USER}:" /etc/subuid
  grep "^${USER}:" /etc/subgid
fi

# ---- 3. Start user services at boot — enable linger ---- #
info "Enabling linger for ${USER} (required for rootless services at boot)..."
sudo loginctl enable-linger "${USER}"
loginctl show-user "${USER}" | grep Linger

info "Priming Quadlet directory and user systemd generator..."
mkdir -p ~/.config/containers/systemd
systemctl --user daemon-reload

# ---- 4. Host knobs some containers need ---- #
info "Checking /dev/net/tun (needed by netbird, gluetun)..."
if [[ -e /dev/net/tun ]]; then
  ls -l /dev/net/tun
else
  warn "/dev/net/tun missing, loading tun module..."
  sudo modprobe tun
fi

# ---- 5. Shared proxy network (optional) ---- #
read -rp "  Create shared 'proxy' Quadlet network for reverse-proxied containers? [y/N]: " _PROXY
if [[ "${_PROXY,,}" == "y" ]]; then
  cat > ~/.config/containers/systemd/proxy.network <<'NETEOF'
[Network]
NetworkName=proxy
NETEOF
  systemctl --user daemon-reload
  info "Created proxy.network — reference it via Network=proxy.network"
else
  info "Skipping shared proxy network."
fi

# ---- 6. Pick a stacks root ---- #
info "Creating ~/containers (app data + .env root)..."
mkdir -p ~/containers

echo ""
echo "  [1/6]  Podman + Quadlet ......... done"
echo "  [2/6]  subuid/subgid ............ done"
echo "  [3/6]  Linger + Quadlet dir ...... done"
echo "  [4/6]  /dev/net/tun .............. done"
echo "  [5/6]  Proxy network ............. ${_PROXY,,}"
echo "  [6/6]  ~/containers ............... done"
echo ""
echo "  Quadlet units   ~/.config/containers/systemd/"
echo "  App data        ~/containers/<app>/"
echo ""
warn "Step 7 (migrating data from a prior Docker setup) is per-container — see each container's README."
echo ""
