#!/usr/bin/env bash
# measure-footprint.sh — snapshot the resource footprint of the container stack
# so you can compare Docker (before) vs rootless Podman (after). READ-ONLY: it
# only reads `free`, `ps`, `systemctl show`, and `<engine> stats/system df`.
#
# Usage:
#   ./measure-footprint.sh docker-before     # run while Docker is the engine
#   ./measure-footprint.sh podman-after       # run after switching to Podman
#   diff <(cat footprint-docker-before-*.txt) <(cat footprint-podman-after-*.txt)
#
# The headline number is "engine overhead": the RAM held by the runtime itself —
# for Docker that's the dockerd + containerd + shim daemons (always resident);
# for rootless Podman there is NO daemon, only a small conmon/pasta per container.
#
# ⚠️ UNTESTED on the host — verify the numbers make sense before trusting them.
set -uo pipefail

LABEL="${1:-snapshot}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="footprint-${LABEL}-${TS}.txt"

log() { printf '%s\n' "$*" | tee -a "$OUT" >/dev/null; }
both() { printf '%s\n' "$*" | tee -a "$OUT"; }
rule() { log "------------------------------------------------------------------"; }

# Sum RSS in KB across processes whose full command line matches an ERE.
sum_rss_kb() { # $1 = extended regex
  ps -eo rss=,args= 2>/dev/null | awk -v re="$1" '$0 ~ re {s+=$1} END{printf "%d", s+0}'
}
mb() { awk -v k="$1" 'BEGIN{printf "%.0f MB", k/1024}'; }

: > "$OUT"
both "# Container footprint — label=$LABEL  host=$(hostname)  $(date)"
both "# kernel: $(uname -srm)"

rule
both "## System memory"
free -h | tee -a "$OUT"

rule
both "## Engine overhead (resident runtime RAM — the key before/after metric)"
DOCKER_RT='dockerd|containerd|containerd-shim|docker-proxy'
PODMAN_RT='[c]onmon|[p]asta|slirp4netns|aardvark-dns'
if command -v docker >/dev/null 2>&1; then
  both "Docker daemons (dockerd+containerd+shims+proxy): $(mb "$(sum_rss_kb "$DOCKER_RT")")"
fi
if command -v podman >/dev/null 2>&1; then
  both "Podman helpers (conmon+pasta/slirp+aardvark):      $(mb "$(sum_rss_kb "$PODMAN_RT")")"
fi

rule
both "## systemd service memory (Docker only — Podman rootless has no daemon)"
for svc in docker.service containerd.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    cur=$(systemctl show -p MemoryCurrent --value "$svc" 2>/dev/null)
    case "$cur" in ''|'[not set]'|18446744073709551615) cur="(n/a)";; *) cur="$(mb "$((cur/1024))")";; esac
    both "$svc MemoryCurrent: $cur"
  fi
done

rule
both "## Per-container live usage"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  both "[docker] running containers: $(docker ps -q | wc -l)"
  docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' | tee -a "$OUT"
fi
if command -v podman >/dev/null 2>&1; then
  both "[podman] running containers: $(podman ps -q | wc -l)"
  podman stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPU}}' 2>/dev/null | tee -a "$OUT"
fi

rule
both "## Disk used by images/containers/volumes"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  both "[docker system df]"; docker system df | tee -a "$OUT"
fi
if command -v podman >/dev/null 2>&1; then
  both "[podman system df]"; podman system df | tee -a "$OUT"
fi

rule
both "Saved full snapshot to: $OUT"
