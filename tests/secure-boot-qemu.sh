#!/usr/bin/env bash
set -Eeuo pipefail

iso_path="${1:-artifacts/mo-os-alpha-0.5-amd64.iso}"
boot_timeout="${MO_SECURE_BOOT_TIMEOUT:-420}"
rejection_timeout="${MO_SECURE_BOOT_REJECTION_TIMEOUT:-75}"
diagnostics_dir="${MO_SECURE_BOOT_DIAGNOSTICS_DIR:-}"
marker='MO_OS_BOOT_READY'

[[ -f "$iso_path" ]] || { echo "ISO not found: $iso_path" >&2; exit 1; }
for command_name in \
  grep mkfs.vfat mcopy mmd openssl qemu-system-x86_64 sbverify \
  sha256sum ukify uuidgen virt-fw-vars xorriso; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing Secure Boot test dependency: $command_name" >&2
    exit 1
  }
done

find_ovmf() {
  local code vars
  for code in \
    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
    /usr/share/OVMF/OVMF_CODE.secboot.fd; do
    [[ -f "$code" ]] || continue
    case "$code" in
      *_4M.secboot.fd) vars=/usr/share/OVMF/OVMF_VARS_4M.fd ;;
      *) vars=/usr/share/OVMF/OVMF_VARS.fd ;;
    esac
    [[ -f "$vars" ]] || continue
    printf '%s\n%s\n' "$code" "$vars"
    return 0
  done
  return 1
}

mapfile -t ovmf_paths < <(find_ovmf)
((${#ovmf_paths[@]} == 2)) || {
  echo 'Secure Boot-capable OVMF firmware was not found.' >&2
  exit 1
}
ovmf_code=${ovmf_paths[0]}
ovmf_vars_template=${ovmf_paths[1]}

workdir="$(mktemp -d)"
kernel="$workdir/vmlinuz"
initrd="$workdir/initrd.img"
os_release="$workdir/os-release"
private_key="$workdir/mo-secure-boot-private.pem"
certificate="$workdir/mo-secure-boot-cert.pem"
unsigned_uki="$workdir/mo-os-unsigned.efi"
signed_uki="$workdir/mo-os-signed.efi"
tampered_uki="$workdir/mo-os-tampered.efi"
enrolled_vars="$workdir/OVMF_VARS.enrolled.fd"
vars_report="$workdir/vars-report.txt"
signed_disk="$workdir/signed-fat.img"
unsigned_disk="$workdir/unsigned-fat.img"
tampered_disk="$workdir/tampered-fat.img"
signed_log="$workdir/signed-serial.log"
unsigned_log="$workdir/unsigned-serial.log"
tampered_log="$workdir/tampered-serial.log"
qemu_pid=''

copy_diagnostics() {
  [[ -n "$diagnostics_dir" ]] || return 0
  mkdir -p "$diagnostics_dir"
  for file in \
    "$vars_report" "$signed_log" "$unsigned_log" "$tampered_log"; do
    [[ -f "$file" ]] && cp "$file" "$diagnostics_dir/"
  done
  if [[ -f "$signed_uki" ]]; then
    sha256sum "$signed_uki" > "$diagnostics_dir/signed-uki.sha256"
  fi
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  copy_diagnostics
  rm -rf "$workdir"
}
trap cleanup EXIT

extract_iso_component() {
  local source_path=$1 destination=$2
  xorriso -osirrox on -indev "$iso_path" -extract "$source_path" "$destination" \
    >/dev/null 2>&1 || {
      echo "Unable to extract $source_path from $iso_path" >&2
      exit 1
    }
}

create_boot_disk() {
  local efi_binary=$1 disk_image=$2
  truncate -s 128M "$disk_image"
  mkfs.vfat -n MO_SECBOOT "$disk_image" >/dev/null
  mmd -i "$disk_image" ::/EFI ::/EFI/BOOT
  mcopy -i "$disk_image" "$efi_binary" ::/EFI/BOOT/BOOTX64.EFI
}

launch_qemu() {
  local vars_file=$1 disk_image=$2 log_file=$3
  : > "$log_file"
  qemu-system-x86_64 \
    -machine q35,smm=on \
    -accel tcg,thread=multi \
    -m 2048 \
    -smp 2 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
    -drive "if=pflash,format=raw,file=$vars_file" \
    -drive "file=$disk_image,format=raw,if=virtio" \
    -cdrom "$iso_path" \
    -boot order=c,menu=off \
    -display none \
    -serial "file:$log_file" \
    -monitor none \
    -no-reboot \
    -nic user,model=e1000 &
  qemu_pid=$!
}

stop_qemu() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  qemu_pid=''
}

expect_marker() {
  local vars_file=$1 disk_image=$2 log_file=$3
  local deadline=$((SECONDS + boot_timeout))
  launch_qemu "$vars_file" "$disk_image" "$log_file"
  while ((SECONDS < deadline)); do
    if grep -q "$marker" "$log_file" 2>/dev/null; then
      grep "$marker" "$log_file" | tail -n 1
      stop_qemu
      return 0
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      echo 'QEMU exited before the signed UKI reached MO OS.' >&2
      cat "$log_file" >&2 || true
      qemu_pid=''
      return 1
    fi
    sleep 2
  done
  echo 'Signed UKI did not reach the MO OS boot marker.' >&2
  cat "$log_file" >&2 || true
  stop_qemu
  return 1
}

expect_rejection() {
  local vars_file=$1 disk_image=$2 log_file=$3 description=$4
  local deadline=$((SECONDS + rejection_timeout))
  launch_qemu "$vars_file" "$disk_image" "$log_file"
  while ((SECONDS < deadline)); do
    if grep -q "$marker" "$log_file" 2>/dev/null; then
      echo "Secure Boot accepted $description." >&2
      cat "$log_file" >&2 || true
      stop_qemu
      return 1
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      qemu_pid=''
      echo "Secure Boot rejected $description."
      return 0
    fi
    sleep 2
  done
  stop_qemu
  echo "Secure Boot rejected $description without reaching MO OS."
}

extract_iso_component /live/vmlinuz "$kernel"
extract_iso_component /live/initrd.img "$initrd"
cat > "$os_release" <<'EOF_RELEASE'
NAME="MO OS"
ID=mo-os
VERSION="0.5.0-alpha.2"
VERSION_ID="0.5.0-alpha.2"
EOF_RELEASE

openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 1 \
  -subj '/CN=MO OS Alpha 0.5 CI Secure Boot/' \
  -keyout "$private_key" -out "$certificate" >/dev/null 2>&1
chmod 0600 "$private_key"

cmdline='boot=live components hostname=mo-os username=mo locales=es_PE.UTF-8 keyboard-layouts=latam systemd.unit=mo-boot-test.target console=ttyS0,115200'
ukify build \
  --linux="$kernel" \
  --initrd="$initrd" \
  --cmdline="$cmdline" \
  --os-release="@$os_release" \
  --output="$unsigned_uki"
ukify build \
  --linux="$kernel" \
  --initrd="$initrd" \
  --cmdline="$cmdline" \
  --os-release="@$os_release" \
  --secureboot-private-key="$private_key" \
  --secureboot-certificate="$certificate" \
  --output="$signed_uki"

sbverify --cert "$certificate" "$signed_uki" >/dev/null
if sbverify --cert "$certificate" "$unsigned_uki" >/dev/null 2>&1; then
  echo 'Unsigned UKI unexpectedly contains the trusted signature.' >&2
  exit 1
fi

cp "$signed_uki" "$tampered_uki"
tamper_offset=$(( $(stat -c %s "$tampered_uki") / 2 ))
printf '\xA5' | dd of="$tampered_uki" bs=1 seek="$tamper_offset" conv=notrunc status=none
if sbverify --cert "$certificate" "$tampered_uki" >/dev/null 2>&1; then
  echo 'Tampered UKI retained a valid signature.' >&2
  exit 1
fi

owner_guid="$(uuidgen)"
virt-fw-vars \
  --input "$ovmf_vars_template" \
  --output "$enrolled_vars" \
  --set-pk "$owner_guid" "$certificate" \
  --add-kek "$owner_guid" "$certificate" \
  --add-db "$owner_guid" "$certificate" \
  --secure-boot
virt-fw-vars --input "$enrolled_vars" --print --verbose > "$vars_report"
grep -q 'SecureBoot' "$vars_report"

create_boot_disk "$signed_uki" "$signed_disk"
create_boot_disk "$unsigned_uki" "$unsigned_disk"
create_boot_disk "$tampered_uki" "$tampered_disk"

cp "$enrolled_vars" "$workdir/signed-vars.fd"
expect_marker "$workdir/signed-vars.fd" "$signed_disk" "$signed_log"

cp "$enrolled_vars" "$workdir/unsigned-vars.fd"
expect_rejection "$workdir/unsigned-vars.fd" "$unsigned_disk" "$unsigned_log" 'an unsigned MO OS UKI'

cp "$enrolled_vars" "$workdir/tampered-vars.fd"
expect_rejection "$workdir/tampered-vars.fd" "$tampered_disk" "$tampered_log" 'a modified signed MO OS UKI'

echo 'MO OS Secure Boot UKI acceptance and rejection test passed.'
