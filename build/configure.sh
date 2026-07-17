#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v lb >/dev/null 2>&1 || {
  echo "live-build is required. Install package: live-build" >&2
  exit 1
}

find config/hooks -type f -name '*.hook.*' -exec chmod 0755 {} +

lb config noauto \
  --mode debian \
  --distribution trixie \
  --architectures amd64 \
  --binary-images iso-hybrid \
  --debian-installer none \
  --archive-areas "main contrib non-free-firmware" \
  --security false \
  --apt-recommends false \
  --bootappend-live "boot=live components hostname=mo-os username=mo locales=es_PE.UTF-8 keyboard-layouts=latam systemd.unit=mo-boot-test.target" \
  --iso-application "MO OS Alpha 0.1" \
  --iso-publisher "MO OS Project" \
  --iso-volume "MO_OS_ALPHA_01"

echo "MO OS live-build configuration prepared."
