#!/usr/bin/env bash
set -Eeuo pipefail

iso_path="${1:-artifacts/mo-os-alpha-0.2-amd64.iso}"
install_timeout="${MO_INSTALL_TIMEOUT:-1200}"
boot_timeout="${MO_INSTALLED_BOOT_TIMEOUT:-300}"
diagnostics_dir="${MO_INSTALL_DIAGNOSTICS_DIR:-}"
install_marker='MO_OS_INSTALL_COMPLETE'
boot_marker='MO_OS_INSTALLED_BOOT_READY'

[[ -f "$iso_path" ]] || { echo "ISO not found: $iso_path" >&2; exit 1; }
for command_name in grep qemu-system-x86_64 truncate; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing installer-test dependency: $command_name" >&2
    exit 1
  }
done

workdir="$(mktemp -d)"
disk="$workdir/mo-os-virtual.raw"
install_log="$workdir/install-serial.log"
boot_log="$workdir/installed-serial.log"
qemu_pid=''

copy_diagnostics() {
  [[ -n "$diagnostics_dir" ]] || return 0
  mkdir -p "$diagnostics_dir"
  if [[ -f "$install_log" ]]; then
    cp "$install_log" "$diagnostics_dir/"
  fi
  if [[ -f "$boot_log" ]]; then
    cp "$boot_log" "$diagnostics_dir/"
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

wait_for_marker() {
  local log_file=$1
  local marker=$2
  local timeout_seconds=$3
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
: > "$install_log"

echo 'Booting live ISO and installing onto disposable /dev/vda...'
qemu-system-x86_64 \
  -accel tcg,thread=multi \
  -m 2048 \
  -smp 2 \
  -cdrom "$iso_path" \
  -drive "file=$disk,format=raw,if=virtio" \
  -boot order=d,menu=off \
  -fw_cfg name=opt/mo/install,string=virtual-disk-v1 \
  -display none \
  -serial "file:$install_log" \
  -monitor none \
  -no-reboot \
  -nic user,model=e1000 &
qemu_pid=$!

wait_for_marker "$install_log" "$install_marker" "$install_timeout"
wait_for_poweroff 120

: > "$boot_log"
echo 'Booting installed virtual disk without the ISO...'
qemu-system-x86_64 \
  -accel tcg,thread=multi \
  -m 1536 \
  -smp 2 \
  -drive "file=$disk,format=raw,if=virtio" \
  -boot order=c,menu=off \
  -display none \
  -serial "file:$boot_log" \
  -monitor none \
  -no-reboot \
  -nic user,model=e1000 &
qemu_pid=$!

wait_for_marker "$boot_log" "$boot_marker" "$boot_timeout"
echo 'MO OS virtual disk installation test passed.'
