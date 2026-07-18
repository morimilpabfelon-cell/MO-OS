#!/usr/bin/env bash
set -Eeuo pipefail

iso_path="${1:-artifacts/mo-os-alpha-0.3-amd64.iso}"
authorization_timeout="${MO_INSTALL_AUTH_TIMEOUT:-180}"
install_timeout="${MO_INSTALL_TIMEOUT:-1800}"
boot_timeout="${MO_INSTALLED_BOOT_TIMEOUT:-300}"
diagnostics_dir="${MO_INSTALL_DIAGNOSTICS_DIR:-}"
authorization_marker='MO_OS_INSTALL_AUTHORIZED'
install_marker='MO_OS_INSTALL_COMPLETE'
boot_marker='MO_OS_INSTALLED_BOOT_READY'

[[ -f "$iso_path" ]] || { echo "ISO not found: $iso_path" >&2; exit 1; }
for command_name in grep qemu-system-x86_64 truncate; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing installer-test dependency: $command_name" >&2
    exit 1
  }
done

find_ovmf() {
  local code vars
  for code in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$code" ]] || continue
    case "$code" in
      *_4M.fd) vars=/usr/share/OVMF/OVMF_VARS_4M.fd ;;
      *) vars=/usr/share/OVMF/OVMF_VARS.fd ;;
    esac
    if [[ -f "$vars" ]]; then
      printf '%s\n%s\n' "$code" "$vars"
      return 0
    fi
  done
  return 1
}

mapfile -t ovmf_paths < <(find_ovmf)
((${#ovmf_paths[@]} == 2)) || {
  echo 'OVMF firmware was not found. Install the ovmf package.' >&2
  exit 1
}
ovmf_code=${ovmf_paths[0]}
ovmf_vars_template=${ovmf_paths[1]}

workdir="$(mktemp -d)"
disk="$workdir/mo-os-virtual.raw"
install_vars="$workdir/install-vars.fd"
boot_vars="$workdir/boot-vars.fd"
install_log="$workdir/install-serial.log"
boot_log="$workdir/installed-serial.log"
qemu_pid=''

copy_diagnostics() {
  [[ -n "$diagnostics_dir" ]] || return 0
  mkdir -p "$diagnostics_dir"
  for file in "$install_log" "$boot_log"; do
    [[ -f "$file" ]] && cp "$file" "$diagnostics_dir/"
  done
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

wait_for_marker() {
  local log_file=$1 marker=$2 timeout_seconds=$3
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if grep -q "$marker" "$log_file" 2>/dev/null; then
      grep "$marker" "$log_file" | tail -n 1
      return 0
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      echo "QEMU exited before marker: $marker" >&2
      cat "$log_file" >&2 || true
      return 1
    fi
    sleep 2
  done
  echo "Timed out waiting for marker: $marker" >&2
  cat "$log_file" >&2 || true
  return 1
}

wait_for_poweroff() {
  local timeout_seconds=$1
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      wait "$qemu_pid" 2>/dev/null || true
      qemu_pid=''
      return 0
    fi
    sleep 2
  done
  echo 'Installer completed but QEMU did not power off.' >&2
  return 1
}

truncate -s 12G "$disk"
cp "$ovmf_vars_template" "$install_vars"
: > "$install_log"

echo 'Booting live ISO through OVMF and installing onto disposable /dev/vda...'
qemu-system-x86_64 \
  -machine q35 \
  -accel tcg,thread=multi \
  -m 2048 \
  -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
  -drive "if=pflash,format=raw,file=$install_vars" \
  -cdrom "$iso_path" \
  -drive "id=mo_install_disk,file=$disk,format=raw,if=none" \
  -device virtio-blk-pci,drive=mo_install_disk,serial=MO-INSTALL-VDA-01 \
  -boot order=d,menu=off \
  -display none \
  -serial "file:$install_log" \
  -monitor none \
  -no-reboot \
  -nic user,model=e1000 &
qemu_pid=$!

wait_for_marker "$install_log" "$authorization_marker" "$authorization_timeout"
wait_for_marker "$install_log" "$install_marker" "$install_timeout"
wait_for_poweroff 120

cp "$ovmf_vars_template" "$boot_vars"
: > "$boot_log"
echo 'Booting installed disk through fresh OVMF variables without the ISO...'
qemu-system-x86_64 \
  -machine q35 \
  -accel tcg,thread=multi \
  -m 1536 \
  -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
  -drive "if=pflash,format=raw,file=$boot_vars" \
  -drive "file=$disk,format=raw,if=virtio" \
  -boot order=c,menu=off \
  -display none \
  -serial "file:$boot_log" \
  -monitor none \
  -no-reboot \
  -nic user,model=e1000 &
qemu_pid=$!

wait_for_marker "$boot_log" "$boot_marker" "$boot_timeout"
echo 'MO OS UEFI virtual disk installation test passed.'
