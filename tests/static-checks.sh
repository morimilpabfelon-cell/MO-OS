#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mapfile -t shell_files < <(
  find build tests config/includes.chroot/usr/local -type f -print | sort
)

for file in "${shell_files[@]}"; do
  head_line="$(head -n 1 "$file" || true)"
  case "$head_line" in
    '#!/usr/bin/env bash'|'#!/bin/bash') bash -n "$file" ;;
    '#!/bin/sh') sh -n "$file" ;;
  esac
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    build/*.sh \
    tests/*.sh \
    config/includes.chroot/usr/local/bin/mo \
    config/includes.chroot/usr/local/sbin/mo-dev-init \
    config/includes.chroot/usr/local/sbin/mo-boot-ready \
    config/includes.chroot/usr/local/sbin/mo-install \
    config/includes.chroot/usr/local/sbin/mo-install-autotest \
    config/includes.chroot/usr/local/sbin/mo-installed-ready
else
  echo 'shellcheck not installed; syntax validation completed only.' >&2
fi

package_file=config/package-lists/mo-base.list.chroot
[[ -f "$package_file" ]]
if [[ -n "$(sort "$package_file" | uniq -d)" ]]; then
  echo 'Duplicate packages detected.' >&2
  exit 1
fi
grep -Fxq 'grub-efi-amd64-bin' "$package_file"
grep -Fxq 'dosfstools' "$package_file"

if grep -Eq '(^|/)(apt|pacman)[[:space:]]' config/includes.chroot/usr/local/bin/mo; then
  echo 'The public mo command must not expose direct package-manager mixing.' >&2
  exit 1
fi

installer=config/includes.chroot/usr/local/sbin/mo-install
grep -Fq '[[ "$disk" == /dev/vda ]]' "$installer"
grep -Fq '[[ "$virtual_mode" -eq 1 ]]' "$installer"
grep -Fq '[[ "$firmware" == uefi ]]' "$installer"
grep -Fq '[[ "$erase_confirmed" -eq 1 ]]' "$installer"
grep -Fq '[[ -d /sys/firmware/efi ]]' "$installer"
grep -Fq 'qemu|kvm' "$installer"
grep -Fq 'minimum_bytes=$((8 * 1024 * 1024 * 1024))' "$installer"
grep -Fq 'mkpart ESP fat32 1MiB 513MiB' "$installer"
grep -Fq 'set 1 esp on' "$installer"
grep -Fq 'mkfs.vfat -F 32 -n MO_EFI' "$installer"
grep -Fq 'useradd --create-home' "$installer"
grep -Fq 'passwd --lock "$username"' "$installer"
grep -Fq -- '--target=x86_64-efi' "$installer"
grep -Fq -- '--removable' "$installer"
grep -Fq -- '--no-nvram' "$installer"
grep -Fq 'EFI/BOOT/BOOTX64.EFI' "$installer"
grep -Fq 'MO_OS_INSTALL_COMPLETE' "$installer"
if grep -Eq "^disk=['\"]/dev/" "$installer"; then
  echo 'Installer must not define a default block device.' >&2
  exit 1
fi

mo_command=config/includes.chroot/usr/local/bin/mo
autotest=config/includes.chroot/usr/local/sbin/mo-install-autotest
grep -q 'archlinux-bootstrap' config/includes.chroot/usr/local/sbin/mo-dev-init
grep -q 'archive_sha256=' config/includes.chroot/usr/local/sbin/mo-dev-init
grep -q 'MO_OS_BOOT_READY' config/includes.chroot/usr/local/sbin/mo-boot-ready
grep -q 'MO_OS_INSTALLED_BOOT_READY' config/includes.chroot/usr/local/sbin/mo-installed-ready
grep -q 'MO_OS_INSTALL_TOKEN' "$autotest"
grep -q 'MO_OS_INSTALL_AUTHORIZED' "$autotest"
grep -q 'MO-INSTALL-VDA-01' "$autotest"
grep -q '/bin/bash /usr/local/sbin/mo-install' "$autotest"
grep -q 'OVMF_CODE' tests/install-qemu.sh
grep -q 'OVMF_VARS' tests/install-qemu.sh
grep -q 'machine q35' tests/install-qemu.sh
grep -q 'virtio-blk-pci,drive=mo_install_disk,serial=MO-INSTALL-VDA-01' tests/install-qemu.sh
grep -q 'fresh OVMF variables' tests/install-qemu.sh
grep -q 'systemd.unit=mo-boot-test.target' build/configure.sh
grep -q -- '--security false' build/configure.sh
grep -q 'trixie-security' config/archives/mo-security.list.chroot
grep -q 'trixie-security' config/archives/mo-security.list.binary
grep -q 'bootloader_source=/usr/share/live/build/bootloaders' build/configure.sh
grep -q 'timeout 50' build/configure.sh
grep -q 'set timeout=5' build/configure.sh
grep -q 'mo-install-autotest.service' config/includes.chroot/etc/systemd/system/mo-boot-test.target
grep -q 'ExecStart=/bin/bash /usr/local/sbin/mo-install-autotest run' config/includes.chroot/etc/systemd/system/mo-install-autotest.service
grep -q 'ExecStart=/bin/bash /usr/local/sbin/mo-installed-ready' config/includes.chroot/etc/systemd/system/mo-installed-ready.service
grep -q 'WantedBy=multi-user.target' config/includes.chroot/etc/systemd/system/mo-installed-ready.service
grep -q 'mo install --virtual --firmware uefi --disk /dev/vda --erase --username NAME' "$mo_command"
grep -q 'make install-test' Makefile
grep -q '0.3.0-alpha.1' VERSION
grep -q '0.3.0-alpha.1' config/includes.chroot/etc/mo-release

echo 'MO OS static checks passed.'
