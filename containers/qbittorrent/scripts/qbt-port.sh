#!/bin/sh
# Runs INSIDE the gluetun container, called by gluetun via
# VPN_PORT_FORWARDING_UP_COMMAND whenever ProtonVPN assigns or renews the
# forwarded port. It pushes that port into qBittorrent's listening port.
#
# gluetun and qBittorrent share ONE network namespace
# (network_mode: service:gluetun), so qBittorrent's WebUI is on localhost:8080
# from in here. qBittorrent must have "Bypass authentication for clients on
# localhost" enabled (Settings -> Web UI) so this needs no login.
#
# Arg $1 is gluetun's {{PORT}} template value.
set -u
PORT="${1:-}"
[ -z "$PORT" ] && { echo "qbt-port: no port given" >&2; exit 0; }

URL="http://127.0.0.1:8080/api/v2/app/setPreferences"
DATA="json={\"listen_port\":${PORT}}"

# qBittorrent's WebUI can take a while to come up after a reboot (slow disk /
# recheck). gluetun fires this once when the port is obtained, so retry
# generously (60 x 5s = 5 min) to ride out a slow qBittorrent startup.
i=1
while [ "$i" -le 60 ]; do
  if wget -q -O- --post-data="$DATA" "$URL" >/dev/null 2>&1; then
    echo "qbt-port: set qBittorrent listening port to $PORT"
    exit 0
  fi
  sleep 5
  i=$((i + 1))
done

echo "qbt-port: FAILED to set port $PORT (is qBittorrent up + localhost auth bypass on?)" >&2
exit 1
