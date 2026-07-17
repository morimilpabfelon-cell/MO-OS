#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mapfile -t shell_files < <(find build tests config/includes.chroot/usr/local -type f -print | sort)

for file in "${shell_files[@]}"; do
  head_line="$(head -n 1 "$file" || true)"
  if [[ "$head_line" == '#!/usr/bin/env bash' || "$head_line" == '#!/bin/bash' ]]; then
    bash -n "$file"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    build/*.sh \
    tests/*.sh \
    config/includes.chroot/usr/local/bin/mo \
    config/includes.chroot/usr/local/sbin/mo-dev-init \
    config/includes.chroot/usr/local/sbin/mo-boot-ready
else
  echo 'shellcheck not installed; syntax validation completed only.' >&2
fi

package_file=config/package-lists/mo-base.list.chroot
[[ -f "$package_file" ]]
if [[ -n "$(sort "$package_file" | uniq -d)" ]]; then
  echo 'Duplicate packages detected.' >&2
  exit 1
fi

if grep -Eq '(^|/)(apt|pacman)[[:space:]]' config/includes.chroot/usr/local/bin/mo; then
  echo 'The public mo command must not expose direct package-manager mixing.' >&2
  exit 1
fi

grep -q 'Disk installation is disabled' config/includes.chroot/usr/local/bin/mo
grep -q 'archlinux-bootstrap' config/includes.chroot/usr/local/sbin/mo-dev-init
grep -q 'archive_sha256=' config/includes.chroot/usr/local/sbin/mo-dev-init
grep -q 'MO_OS_BOOT_READY' config/includes.chroot/usr/local/sbin/mo-boot-ready
grep -q 'systemd.unit=mo-boot-test.target' build/configure.sh
grep -q -- '--security false' build/configure.sh
grep -q 'trixie-security' config/archives/mo-security.list.chroot
grep -q 'trixie-security' config/archives/mo-security.list.binary
grep -q 'Wants=mo-boot-ready.service' config/includes.chroot/etc/systemd/system/mo-boot-test.target

echo 'MO OS static checks passed.'
