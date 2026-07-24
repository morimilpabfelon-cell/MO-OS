#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pycache_dir="$(mktemp -d)"
trap 'rm -rf "$pycache_dir"' EXIT

mapfile -t source_files < <(find build tests config/includes.chroot/usr/local -type f -print | sort)
shell_files=()
for file in "${source_files[@]}"; do
  head_line="$(head -n 1 "$file" || true)"
  case "$head_line" in
    '#!/usr/bin/env bash'|'#!/bin/bash') bash -n "$file"; shell_files+=("$file") ;;
    '#!/bin/sh') sh -n "$file"; shell_files+=("$file") ;;
  esac
done

PYTHONPYCACHEPREFIX="$pycache_dir" python3 -m py_compile \
  config/includes.chroot/usr/local/sbin/mo-bodyd

if find config/includes.chroot -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  echo 'Python bytecode must not exist in the ISO source tree.' >&2
  exit 1
fi
if find config/includes.chroot -type d -name '__pycache__' -print -quit | grep -q .; then
  echo '__pycache__ must not exist in the ISO source tree.' >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -e SC2016 "${shell_files[@]}"
else
  echo 'shellcheck not installed; syntax validation completed only.' >&2
fi

require_fixed() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || {
    echo "Missing required invariant in $file: $pattern" >&2
    exit 1
  }
}

package_file=config/package-lists/mo-base.list.chroot
[[ -f "$package_file" ]]
[[ -z "$(sort "$package_file" | uniq -d)" ]] || {
  echo 'Duplicate packages detected.' >&2
  exit 1
}
for package in btrfs-progs cryptsetup cryptsetup-initramfs grub-efi-amd64-bin dosfstools openssl python3; do
  grep -Fxq "$package" "$package_file"
done

mo_command=config/includes.chroot/usr/local/bin/mo
installer=config/includes.chroot/usr/local/sbin/mo-install
recovery=config/includes.chroot/usr/local/sbin/mo-recovery
snapshot=config/includes.chroot/usr/local/sbin/mo-snapshot
updater=config/includes.chroot/usr/local/sbin/mo-update
executor=config/includes.chroot/usr/local/sbin/mo-bodyd
executor_service=config/includes.chroot/etc/systemd/system/mo-bodyd.service
executor_doc=docs/MORIMIL-EXECUTOR.md
executor_test=tests/executor-signature.sh
arch_test=tests/arch-dispatch.sh
arch_status_test=tests/executor-arch-status.sh
dispatch=config/includes.chroot/usr/local/libexec/mo-arch-dispatch
worker=config/includes.chroot/usr/local/libexec/mo-arch-worker
dev_init=config/includes.chroot/usr/local/sbin/mo-dev-init
install_autotest=config/includes.chroot/usr/local/sbin/mo-install-autotest
recovery_autotest=config/includes.chroot/usr/local/sbin/mo-recovery-autotest
mutation_service=config/includes.chroot/etc/systemd/system/mo-recovery-test-mutate.service
verify_service=config/includes.chroot/etc/systemd/system/mo-recovery-verify.service
secure_boot_test=tests/secure-boot-qemu.sh
workflow=.github/workflows/boot-candidate.yml
configure=build/configure.sh

if grep -Eq '(^|/)(apt|pacman)[[:space:]]' "$mo_command"; then
  echo 'The public mo command must not expose direct package-manager mixing.' >&2
  exit 1
fi

# Encrypted virtual installer and recovery boundary.
for invariant in \
  '[[ "$disk" == /dev/vda ]]' \
  '[[ "$virtual_mode" -eq 1 ]]' \
  '[[ "$firmware" == uefi ]]' \
  '[[ "$erase_confirmed" -eq 1 ]]' \
  '[[ -d /sys/firmware/efi ]]' \
  'minimum_bytes=$((8 * 1024 * 1024 * 1024))' \
  'mkpart ESP fat32 1MiB 513MiB' \
  'mkpart MO_BOOT ext4 513MiB 1537MiB' \
  'mkpart MO_CRYPT 1537MiB 100%' \
  'cryptsetup luksFormat --type luks2' \
  'mkfs.btrfs -f -L MO_ROOT' \
  'btrfs subvolume create "$top_mount/@"' \
  'btrfs subvolume create "$top_mount/@home"' \
  'btrfs subvolume create "$top_mount/@snapshots"' \
  'luks,initramfs' \
  'subvol=@home' \
  'btrfs subvolume snapshot -r "$target" "$target/.snapshots/initial"' \
  '--target=x86_64-efi' '--removable' '--no-nvram' \
  'EFI/BOOT/BOOTX64.EFI' 'MO_OS_INSTALL_COMPLETE' \
  'release_file=/etc/mo-release' 'MO_INSTALLER_VERSION=$mo_version'; do
  require_fixed "$invariant" "$installer"
done
require_fixed 'qemu|kvm' "$installer"
if grep -Eq "^disk=['\"]/dev/" "$installer"; then
  echo 'Installer must not define a default block device.' >&2
  exit 1
fi
if grep -Fq '0.4.0-alpha.1' "$installer" || grep -Fq 'Alpha 0.4' "$installer"; then
  echo 'Installer contains stale Alpha 0.4 metadata.' >&2
  exit 1
fi

for pair in \
  "$install_autotest:MO-INSTALL-VDA-01" \
  "$install_autotest:MO_OS_INSTALL_AUTHORIZED" \
  "$recovery_autotest:MO-RECOVERY-VDA-01" \
  "$recovery_autotest:MO_OS_RECOVERY_AUTHORIZED" \
  "$recovery:MO_OS_ROLLBACK_COMPLETE" \
  "$recovery:home=preserved" \
  "$snapshot:MO_OS_SNAPSHOT_CREATED"; do
  require_fixed "${pair#*:}" "${pair%%:*}"
done
require_fixed 'btrfs subvolume delete "$top_mount/@"' "$recovery"
require_fixed 'btrfs subvolume snapshot "$top_mount/@snapshots/$snapshot" "$top_mount/@"' "$recovery"
require_fixed 'MO_OS_MUTATION_READY' config/includes.chroot/usr/local/sbin/mo-recovery-test-mutate
require_fixed 'MO_OS_ROLLBACK_VERIFIED' config/includes.chroot/usr/local/sbin/mo-recovery-verify
require_fixed 'ConditionPathExists=/boot/mo-recovery-test-once' "$mutation_service"
require_fixed 'ConditionPathExists=/boot/mo-recovery-test-completed' "$verify_service"
if grep -q 'mo-installed-ready.service' "$mutation_service" "$verify_service"; then
  echo 'Recovery validation services must not depend on mo-installed-ready.service.' >&2
  exit 1
fi

# Signed update boundary.
for invariant in \
  'default_trust_key=/etc/mo/trust/update-public.pem' \
  'openssl dgst -sha256 -verify' \
  'manifest signature verification failed' \
  'MO_UPDATE_SEQUENCE' '((sequence > current_sequence))' \
  'btrfs subvolume snapshot -r "$root"' \
  'allowed_prefix = pathlib.PurePosixPath("usr/local/share/mo-update")' \
  'not member.isfile()' 'MO_UPDATE_ALLOW_TEST_ROOT' 'MO_OS_UPDATE_APPLIED'; do
  require_fixed "$invariant" "$updater"
done
require_fixed 'Replay protection failed' tests/update-signature.sh
require_fixed 'Tampered payload was accepted' tests/update-signature.sh

# Morimil executor and Debian-governed Arch boundary.
for invariant in \
  'SCHEMA_REQUEST = "morimil.executor.request.v0.1"' \
  'SCHEMA_RECEIPT = "morimil.executor.receipt.v0.1"' \
  'SUPPORTED_OPERATIONS = {"system.status"}' \
  'DELEGATED_OPERATIONS = {"arch.status"}' \
  'MAX_SIGNATURE_TEXT_BYTES = 256' \
  'ED25519_SPKI_PREFIX' \
  'not_ed25519' \
  'RequestContext' \
  'os.O_EXCL' \
  'request_replay_rejected' \
  'identity_authority_invalid' \
  'executor_keypair_mismatch' \
  'request_signature_invalid' \
  'receipt.sig' 'journal.jsonl' 'quarantine'; do
  require_fixed "$invariant" "$executor"
done
if grep -Fq 'shell=True' "$executor"; then
  echo 'The executor must never invoke subprocesses through a shell.' >&2
  exit 1
fi
for invariant in \
  'NoNewPrivileges=yes' 'ProtectSystem=strict' 'ProtectHome=yes' \
  'MemoryDenyWriteExecute=yes' 'CapabilityBoundingSet=' \
  'ReadWritePaths=/var/lib/mo-bodyd' \
  'ConditionPathExists=/etc/mo/executor/pairing.json'; do
  require_fixed "$invariant" "$executor_service"
done
for invariant in \
  'MO_ARCH_DISPATCH_WORKER_HOST' 'MO_ARCH_DISPATCH_NSENTER' \
  'arch_worker_integrity_mismatch' 'sha256sum_cmd=/usr/bin/sha256sum' \
  'nsenter_cmd=/usr/bin/nsenter' 'proc_root=/proc' \
  '--property=RootDirectory' '--property=Leader' \
  '--mount --uts --ipc --net --pid --cgroup' \
  'arch_domain_leader_root_mismatch' 'arch_domain_identity_changed' \
  'mo-arch-worker' 'status'; do
  require_fixed "$invariant" "$dispatch"
done
if grep -Fq '"$machinectl_cmd" shell' "$dispatch"; then
  echo 'The Arch dispatcher must not depend on machinectl shell or the guest system bus.' >&2
  exit 1
fi
require_fixed 'mo.arch.worker.status.v0.1' "$worker"
require_fixed 'arch_worker_integrity_mismatch' "$arch_test"
require_fixed 'MO_ARCH_DISPATCH_NSENTER' "$arch_test"
require_fixed 'arch_domain_identity_changed' "$arch_test"
require_fixed 'Replay request was accepted under another bundle name.' "$executor_test"
require_fixed 'not_ed25519' "$executor_test"
require_fixed 'request_signature_size_invalid' "$executor_test"
require_fixed 'receipt["status"] == "failed"' "$arch_status_test"
require_fixed 'host_worker_sha=' "$dev_init"
require_fixed 'domain_worker_sha=' "$dev_init"
require_fixed 'system.status' "$executor_doc"
require_fixed 'arch.status' "$executor_doc"
require_fixed 'make executor-test' "$workflow"
require_fixed 'make arch-dispatch-test' "$workflow"

# Secure Boot UKI boundary.
for invariant in \
  'OVMF_CODE_4M.secboot.fd' 'ukify build' \
  '--secureboot-private-key="$private_key"' \
  '--secureboot-certificate="$certificate"' \
  'sbverify --cert "$certificate" "$signed_uki"' \
  'virt-fw-vars' '--set-pk "$owner_guid" "$certificate"' \
  '--add-kek "$owner_guid" "$certificate"' \
  '--add-db "$owner_guid" "$certificate"' '--secure-boot' \
  'expect_marker "$workdir/signed-vars.fd"' \
  "'an unsigned MO OS UKI'" "'a modified signed MO OS UKI'" \
  "marker='MO_OS_BOOT_READY'"; do
  require_fixed "$invariant" "$secure_boot_test"
done
for invariant in systemd-ukify python3-virt-firmware sbsigntool make\ secure-boot-test MO_SECURE_BOOT_DIAGNOSTICS_DIR; do
  require_fixed "$invariant" "$workflow"
done

if find . -type f \( -name '*.key' -o -name '*private*.pem' \) -print -quit | grep -q .; then
  echo 'Private signing key files must never be committed.' >&2
  exit 1
fi
if grep -R -n --include='*.pem' --include='*.key' -- 'PRIVATE KEY' config docs 2>/dev/null; then
  echo 'Private signing key material must never be committed.' >&2
  exit 1
fi

# Build, boot and public CLI invariants.
for invariant in \
  'systemd.unit=mo-boot-test.target' '--security false' \
  'bootloader_source=/usr/share/live/build/bootloaders' \
  'timeout 50' 'set timeout=5' \
  'MO OS Alpha 0.6 Morimil Executor' 'MO_OS_ALPHA_06' \
  'Python bytecode must not be packaged' '__pycache__'; do
  require_fixed "$invariant" "$configure"
done
require_fixed 'trixie-security' config/archives/mo-security.list.chroot
require_fixed 'trixie-security' config/archives/mo-security.list.binary
for invariant in \
  'mo executor pair --controller-key FILE --instance-id ID --controller-body-id ID' \
  'mo install --virtual --firmware uefi --disk /dev/vda --erase --username NAME' \
  'mo recovery rollback --virtual --firmware uefi --disk /dev/vda --snapshot NAME' \
  'mo update verify --bundle DIR' 'mo-arch-dispatch' 'mo-arch-worker'; do
  require_fixed "$invariant" "$mo_command"
done
for target in install-test update-test executor-test arch-dispatch-test secure-boot-test; do
  require_fixed "$target" Makefile
done
require_fixed '0.6.0-alpha.1' VERSION
require_fixed '0.6.0-alpha.1' config/includes.chroot/etc/mo-release

echo 'MO OS Debian governance, Arch execution, encrypted recovery, updates and Secure Boot checks passed.'
