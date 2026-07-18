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
  shellcheck -e SC2016 \
    build/*.sh \
    tests/*.sh \
    config/includes.chroot/usr/local/bin/mo \
    config/includes.chroot/usr/local/sbin/mo-dev-init \
    config/includes.chroot/usr/local/sbin/mo-boot-ready \
    config/includes.chroot/usr/local/sbin/mo-install \
    config/includes.chroot/usr/local/sbin/mo-install-autotest \
    config/includes.chroot/usr/local/sbin/mo-installed-ready \
    config/includes.chroot/usr/local/sbin/mo-recovery \
    config/includes.chroot/usr/local/sbin/mo-recovery-autotest \
    config/includes.chroot/usr/local/sbin/mo-recovery-test-mutate \
    config/includes.chroot/usr/local/sbin/mo-recovery-verify \
    config/includes.chroot/usr/local/sbin/mo-snapshot
else
  echo 'shellcheck not installed; syntax validation completed only.' >&2
fi

package_file=config/package-lists/mo-base.list.chroot
[[ -f "$package_file" ]]
if [[ -n "$(sort "$package_file" | uniq -d)" ]]; then
  echo 'Duplicate packages detected.' >&2
  exit 1
fi
grep -Fxq 'btrfs-progs' "$package_file"
grep -Fxq 'cryptsetup' "$package_file"
grep -Fxq 'cryptsetup-initramfs' "$package_file"
grep -Fxq 'grub-efi-amd64-bin' "$package_file"
grep -Fxq 'dosfstools' "$package_file"

if grep -Eq '(^|/)(apt|pacman)[[:space:]]' config/includes.chroot/usr/local/bin/mo; then
  echo 'The public mo command must not expose direct package-manager mixing.' >&2
  exit 1
fi

installer=config/includes.chroot/usr/local/sbin/mo-install
recovery=config/includes.chroot/usr/local/sbin/mo-recovery
snapshot=config/includes.chroot/usr/local/sbin/mo-snapshot
mo_command=config/includes.chroot/usr/local/bin/mo
install_autotest=config/includes.chroot/usr/local/sbin/mo-install-autotest
recovery_autotest=config/includes.chroot/usr/local/sbin/mo-recovery-autotest

grep -Fq '[[ "$disk" == /dev/vda ]]' "$installer"
grep -Fq '[[ "$virtual_mode" -eq 1 ]]' "$installer"
grep -Fq '[[ "$firmware" == uefi ]]' "$installer"
grep -Fq '[[ "$erase_confirmed" -eq 1 ]]' "$installer"
grep -Fq '[[ -d /sys/firmware/efi ]]' "$installer"
grep -Fq 'qemu|kvm' "$installer"
grep -Fq 'minimum_bytes=$((8 * 1024 * 1024 * 1024))' "$installer"
grep -Fq 'mkpart ESP fat32 1MiB 513MiB' "$installer"
grep -Fq 'mkpart MO_BOOT ext4 513MiB 1537MiB' "$installer"
grep -Fq 'mkpart MO_CRYPT 1537MiB 100%' "$installer"
grep -Fq 'cryptsetup luksFormat --type luks2' "$installer"
grep -Fq 'mkfs.btrfs -f -L MO_ROOT' "$installer"
grep -Fq 'btrfs subvolume create "$top_mount/@"' "$installer"
grep -Fq 'btrfs subvolume create "$top_mount/@home"' "$installer"
grep -Fq 'btrfs subvolume create "$top_mount/@snapshots"' "$installer"
grep -Fq 'luks,initramfs' "$installer"
grep -Fq 'subvol=@home' "$installer"
grep -Fq 'btrfs subvolume snapshot -r "$target" "$target/.snapshots/initial"' "$installer"
grep -Fq -- '--target=x86_64-efi' "$installer"
grep -Fq -- '--removable' "$installer"
grep -Fq -- '--no-nvram' "$installer"
grep -Fq 'EFI/BOOT/BOOTX64.EFI' "$installer"
grep -Fq 'MO_OS_INSTALL_COMPLETE' "$installer"
if grep -Eq "^disk=['\"]/dev/" "$installer"; then
  echo 'Installer must not define a default block device.' >&2
  exit 1
fi

grep -q 'MO-INSTALL-VDA-01' "$install_autotest"
grep -q 'MO_OS_INSTALL_AUTHORIZED' "$install_autotest"
grep -q -- '--key-file "$key_file"' "$install_autotest"
grep -q 'MO-RECOVERY-VDA-01' "$recovery_autotest"
grep -q 'MO_OS_RECOVERY_AUTHORIZED' "$recovery_autotest"
grep -q 'MO_OS_ROLLBACK_COMPLETE' "$recovery"
grep -q 'home=preserved' "$recovery"
grep -q 'btrfs subvolume delete "$top_mount/@"' "$recovery"
grep -q 'btrfs subvolume snapshot "$top_mount/@snapshots/$snapshot" "$top_mount/@"' "$recovery"
grep -q 'MO_OS_SNAPSHOT_CREATED' "$snapshot"
grep -q 'MO_OS_MUTATION_READY' config/includes.chroot/usr/local/sbin/mo-recovery-test-mutate
grep -q 'MO_OS_ROLLBACK_VERIFIED' config/includes.chroot/usr/local/sbin/mo-recovery-verify

grep -q 'mo-recovery-autotest.service' config/includes.chroot/etc/systemd/system/mo-boot-test.target
grep -q 'ExecStart=/bin/bash /usr/local/sbin/mo-recovery-autotest' config/includes.chroot/etc/systemd/system/mo-recovery-autotest.service
grep -q 'ConditionPathExists=/boot/mo-recovery-test-once' config/includes.chroot/etc/systemd/system/mo-recovery-test-mutate.service
grep -q 'ConditionPathExists=/boot/mo-recovery-test-completed' config/includes.chroot/etc/systemd/system/mo-recovery-verify.service

grep -q 'expect' tests/install-qemu.sh
grep -q 'MO-RECOVERY-VDA-01' tests/install-qemu.sh
grep -q 'MO_OS_ROLLBACK_VERIFIED' tests/install-qemu.sh
grep -q 'fresh OVMF variables' tests/install-qemu.sh
grep -q 'systemd.unit=mo-boot-test.target' build/configure.sh
grep -q -- '--security false' build/configure.sh
grep -q 'trixie-security' config/archives/mo-security.list.chroot
grep -q 'trixie-security' config/archives/mo-security.list.binary
grep -q 'bootloader_source=/usr/share/live/build/bootloaders' build/configure.sh
grep -q 'timeout 50' build/configure.sh
grep -q 'set timeout=5' build/configure.sh

grep -q 'mo install --virtual --firmware uefi --disk /dev/vda --erase --username NAME' "$mo_command"
grep -q 'mo recovery rollback --virtual --firmware uefi --disk /dev/vda --snapshot NAME' "$mo_command"
grep -q 'snapshot)' "$mo_command"
grep -q 'recovery)' "$mo_command"
grep -q 'make install-test' Makefile
grep -q '0.4.0-alpha.1' VERSION
grep -q '0.4.0-alpha.1' config/includes.chroot/etc/mo-release

echo 'MO OS encrypted recovery static checks passed.'
