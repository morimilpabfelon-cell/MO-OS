#!/usr/bin/env bash
set -Eeuo pipefail

iso_path="${1:-artifacts/mo-os-alpha-0.1-amd64.iso}"
timeout_seconds="${MO_BOOT_TIMEOUT:-300}"
marker='MO_OS_BOOT_READY'

[[ -f "$iso_path" ]] || {
  echo "ISO not found: $iso_path" >&2
  exit 1
}

for command_name in qemu-system-x86_64 grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing boot-test dependency: $command_name" >&2
    exit 1
  }
done

log_file="$(mktemp)"
qemu_pid=''
cleanup() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -f "$log_file"
}
trap cleanup EXIT

qemu-system-x86_64 \
  -accel tcg,thread=multi \
  -m 1536 \
  -smp 2 \
  -cdrom "$iso_path" \
  -boot order=d,menu=off \
  -display none \
  -serial "file:$log_file" \
  -monitor none \
  -no-reboot \
  -nic user,model=e1000 &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
  if grep -q "$marker" "$log_file"; then
    grep "$marker" "$log_file" | tail -n 1
    echo 'MO OS QEMU boot test passed.'
    exit 0
  fi

  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo 'QEMU exited before MO OS reached the boot-ready target.' >&2
    cat "$log_file" >&2
    exit 1
  fi
  sleep 2
done

echo "MO OS did not reach the boot-ready target within ${timeout_seconds}s." >&2
cat "$log_file" >&2
exit 1
