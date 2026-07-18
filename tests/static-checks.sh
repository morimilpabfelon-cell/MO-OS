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
    config/includes.chroot/usr/local/sbin/mo-snapshot \
    config/includes.chroot/usr/local/sbin/mo-update
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
grep -Fxq 'openssl' "$package_file"

if grep -Eq '(^|/)(apt|pacman)[[:space:]]' config/includes.chroot/usr/local/bin/mo; then
  echo 'The public mo command must not expose direct package-manager mixing.' >&2
  exit 1
fi

installer=config/includes.chroot/usr/local/sbin/mo-install
recovery=config/includes.chroot/usr/local/sbin/mo-recovery
snapshot=config/includes.chroot/usr/local/sbin/mo-snapshot
updater=config/includes.chroot/usr/local/sbin/mo-update
mo_command=config/includes.chroot/usr/local/bin/mo
install_autotest=config/includes.chroot/usr/local/sbin/mo-install-autotest
recovery_autotest=config/includes.chroot/usr/local/sbin/mo-recovery-autotest
mutation_service=config/includes.chroot/etc/systemd/system/mo-recovery-test-mutate.service
verify_service=config/includes.chroot/etc/systemd/system/mo-recovery-verify.service
secure_boot_test=tests/secure-boot-qemu.sh
workflow=.github/workflows/boot-candidate.yml

# Encrypted installer and recovery boundary.
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
grep -q 'ConditionPathExists=/boot/mo-recovery-test-once' "$mutation_service"
grep -q 'ConditionPathExists=/boot/mo-recovery-test-completed' "$verify_service"
grep -q 'After=local-fs.target' "$mutation_service"
grep -q 'After=local-fs.target' "$verify_service"
grep -q 'WantedBy=multi-user.target' "$mutation_service"
grep -q 'WantedBy=multi-user.target' "$verify_service"
if grep -q 'mo-installed-ready.service' "$mutation_service" "$verify_service"; then
  echo 'Recovery validation services must not depend on mo-installed-ready.service.' >&2
  exit 1
fi

# Signed update boundary.
grep -Fq 'default_trust_key=/etc/mo/trust/update-public.pem' "$updater"
grep -Fq 'openssl dgst -sha256 -verify' "$updater"
grep -Fq 'manifest signature verification failed' "$updater"
grep -Fq 'MO_UPDATE_SEQUENCE' "$updater"
grep -Fq '((sequence > current_sequence))' "$updater"
grep -Fq 'btrfs subvolume snapshot -r "$root"' "$updater"
grep -Fq 'allowed_prefix = pathlib.PurePosixPath("usr/local/share/mo-update")' "$updater"
grep -Fq 'not member.isfile()' "$updater"
grep -Fq 'MO_UPDATE_ALLOW_TEST_ROOT' "$updater"
grep -Fq 'MO_OS_UPDATE_APPLIED' "$updater"
grep -Fq 'openssl genpkey -algorithm RSA' tests/update-signature.sh
grep -Fq 'Replay protection failed' tests/update-signature.sh
grep -Fq 'Tampered payload was accepted' tests/update-signature.sh
grep -Fq '.snapshots/pre-update-1' tests/update-signature.sh

# Secure Boot UKI boundary.
grep -Fq 'OVMF_CODE_4M.secboot.fd' "$secure_boot_test"
grep -Fq 'ukify build' "$secure_boot_test"
grep -Fq -- '--secureboot-private-key="$private_key"' "$secure_boot_test"
grep -Fq -- '--secureboot-certificate="$certificate"' "$secure_boot_test"
grep -Fq 'sbverify --cert "$certificate" "$signed_uki"' "$secure_boot_test"
grep -Fq 'virt-fw-vars' "$secure_boot_test"
grep -Fq -- '--set-pk "$owner_guid" "$certificate"' "$secure_boot_test"
grep -Fq -- '--add-kek "$owner_guid" "$certificate"' "$secure_boot_test"
grep -Fq -- '--add-db "$owner_guid" "$certificate"' "$secure_boot_test"
grep -Fq -- '--secure-boot' "$secure_boot_test"
grep -Fq 'expect_marker "$workdir/signed-vars.fd"' "$secure_boot_test"
grep -Fq "'an unsigned MO OS UKI'" "$secure_boot_test"
grep -Fq "'a modified signed MO OS UKI'" "$secure_boot_test"
grep -Fq "marker='MO_OS_BOOT_READY'" "$secure_boot_test"
grep -Fq 'private_key="$workdir/mo-secure-boot-private.pem"' "$secure_boot_test"
grep -Fq 'rm -rf "$workdir"' "$secure_boot_test"
grep -Fq 'systemd-ukify' "$workflow"
grep -Fq 'python3-virt-firmware' "$workflow"
grep -Fq 'sbsigntool' "$workflow"
grep -Fq 'make secure-boot-test' "$workflow"
grep -Fq 'MO_SECURE_BOOT_DIAGNOSTICS_DIR' "$workflow"

if find . -type f \( -name '*.key' -o -name '*private*.pem' \) -print -quit | grep -q .; then
  echo 'Private signing key files must never be committed.' >&2
  exit 1
fi
if grep -R -n --include='*.pem' --include='*.key' -- 'PRIVATE KEY' config docs 2>/dev/null; then
  echo 'Private signing key material must never be committed.' >&2
  exit 1
fi

# Existing build and boot invariants.
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
grep -q 'MO OS Alpha 0.5 Secure Boot' build/configure.sh
grep -q 'MO_OS_ALPHA_05' build/configure.sh

grep -q 'mo install --virtual --firmware uefi --disk /dev/vda --erase --username NAME' "$mo_command"
grep -q 'mo recovery rollback --virtual --firmware uefi --disk /dev/vda --snapshot NAME' "$mo_command"
grep -q 'mo update verify --bundle DIR' "$mo_command"
grep -q 'snapshot)' "$mo_command"
grep -q 'recovery)' "$mo_command"
grep -q 'update)' "$mo_command"
grep -q 'make install-test' Makefile
grep -q 'make update-test' Makefile
grep -q 'make secure-boot-test' Makefile
grep -q '0.5.0-alpha.2' VERSION
grep -q '0.5.0-alpha.2' config/includes.chroot/etc/mo-release

echo 'MO OS encrypted recovery, signed updates and Secure Boot static checks passed.'
