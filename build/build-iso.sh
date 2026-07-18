#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ISO construction requires root privileges." >&2
  exit 1
fi

for command_name in lb debootstrap xorriso mksquashfs; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing build dependency: $command_name" >&2
    exit 1
  }
done

bash build/configure.sh
mkdir -p artifacts
lb build

source_iso="live-image-amd64.hybrid.iso"
target_iso="artifacts/mo-os-alpha-0.3-amd64.iso"

[[ -f "$source_iso" ]] || {
  echo "live-build completed without producing $source_iso" >&2
  exit 1
}

mv -f "$source_iso" "$target_iso"
sha256sum "$target_iso" > "${target_iso}.sha256"
echo "Created $target_iso"
