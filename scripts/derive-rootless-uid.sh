#!/usr/bin/env bash
# derive-rootless-uid.sh <container-uid> [host-user]
#
# Prints the REAL host UID that a given in-container UID resolves to under
# Podman's default rootless mapping (no UserNS= set) for host-user (default:
# the current user). Use this instead of ever hardcoding a subuid-derived
# number — the number is host-specific (depends on /etc/subuid), the FORMULA
# is not.
#
# Why this exists: a container with no UserNS= maps container UID 0 -> your
# real UID, and container UID 1..65535 -> your /etc/subuid range, contiguous
# from its start. So container UID N (N >= 1) is always:
#   host_uid = subuid_start + (N - 1)
# Verified against the kernel's own /proc/<pid>/uid_map - this is not a guess.
#
# Typical use: a container's PUID=N needs write access to a bind-mounted
# directory that already has real files on it (migrated data, a foreign
# filesystem like NTFS/exFAT mounted with a fixed uid=). Run this to get the
# real number, then either:
#   sudo chown -R <result>:<result> <path>          # native filesystem (ext4/xfs/btrfs)
#   # or edit /etc/fstab's uid=/gid= to <result>      # foreign filesystem (ntfs-3g/exfat)
set -euo pipefail

CUID="${1:?Usage: $0 <container-uid> [host-user]}"
USERNAME="${2:-$(whoami)}"

SUBUID_START=$(awk -F: -v u="$USERNAME" '$1==u {print $2}' /etc/subuid)
if [ -z "$SUBUID_START" ]; then
  echo "No /etc/subuid entry for '$USERNAME' — see docs/host-setup.md ​§2." >&2
  exit 1
fi

if [ "$CUID" -eq 0 ]; then
  echo "Container UID 0 (root) maps to your REAL UID under default rootless mapping: $(id -u "$USERNAME")"
else
  echo $((SUBUID_START + CUID - 1))
fi
