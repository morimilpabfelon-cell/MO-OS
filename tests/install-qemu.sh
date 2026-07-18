#!/usr/bin/env bash
set -Eeuo pipefail

iso_path="${1:-artifacts/mo-os-alpha-0.4-amd64.iso}"
authorization_timeout="${MO_INSTALL_AUTH_TIMEOUT:-180}"
install_timeout="${MO_INSTALL_TIMEOUT:-1800}"
boot_timeout="${MO_INSTALLED_BOOT_TIMEOUT:-420}"
recovery_timeout="${MO_RECOVERY_TIMEOUT:-900}"
diagnostics_dir="${MO_INSTALL_DIAGNOSTICS_DIR:-}"
ci_passphrase='mo-os-alpha-0.4-ci-only'
authorization_marker='MO_OS_INSTALL_AUTHORIZED'
install_marker='MO_OS_INSTALL_COMPLETE'
boot_marker='MO_OS_INSTALLED_BOOT_READY'
mutation_marker='MO_OS_MUTATION_READY'
recovery_authorization_marker='MO_OS_RECOVERY_AUTHORIZED'
rollback_marker='MO_OS_ROLLBACK_COMPLETE'
verified_marker='MO_OS_ROLLBACK_VERIFIED'

[[ -f "$iso_path" ]] || { echo "ISO not found: $iso_path" >&2; exit 1; }
for command_name in expect grep qemu-system-x86_64 truncate; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing encrypted installer-test dependency: $command_name" >&2
    exit 1
  }
done

find_ovmf() {
  local code vars
  for code in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$code" ]] || continue
    case "$code" in
      *_4M.fd) vars=/usr/share/OVMF/OVMF_VARS_4M.fd ;;
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
  echo 'OVMF firmware was not found. Install the ovmf package.' >&2
  exit 1
}
ovmf_code=${ovmf_paths[0]}
ovmf_vars_template=${ovmf_paths[1]}

workdir="$(mktemp -d)"
disk="$workdir/mo-os-encrypted.raw"
install_vars="$workdir/install-vars.fd"
first_boot_vars="$workdir/first-boot-vars.fd"
recovery_vars="$workdir/recovery-vars.fd"
final_boot_vars="$workdir/final-boot-vars.fd"
install_log="$workdir/install-serial.log"
first_boot_log="$workdir/first-boot-serial.log"
recovery_log="$workdir/recovery-serial.log"
final_boot_log="$workdir/final-boot-serial.log"
qemu_pid=''

copy_diagnostics() {
  [[ -n "$diagnostics_dir" ]] || return 0
  mkdir -p "$diagnostics_dir"
  for file in "$install_log" "$first_boot_log" "$recovery_log" "$final_boot_log"; do
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
  echo 'QEMU did not power off after completing the requested phase.' >&2
  return 1
}

boot_encrypted_disk() {
  local vars_file=$1 log_file=$2 required_marker=$3 timeout_seconds=$4
  cp "$ovmf_vars_template" "$vars_file"
  : > "$log_file"

  MO_EXPECT_OVMF_CODE="$ovmf_code" \
  MO_EXPECT_OVMF_VARS="$vars_file" \
  MO_EXPECT_DISK="$disk" \
  MO_EXPECT_LOG="$log_file" \
  MO_EXPECT_PASSPHRASE="$ci_passphrase" \
  MO_EXPECT_MARKER="$required_marker" \
  MO_EXPECT_TIMEOUT="$timeout_seconds" \
  expect <<'EXPECT'
    set timeout $env(MO_EXPECT_TIMEOUT)
    log_file -noappend $env(MO_EXPECT_LOG)
    log_user 1
    set marker_seen 0
    spawn qemu-system-x86_64 \
      -machine q35 \
      -accel tcg,thread=multi \
      -m 2048 \
      -smp 2 \
      -drive "if=pflash,format=raw,readonly=on,file=$env(MO_EXPECT_OVMF_CODE)" \
      -drive "if=pflash,format=raw,file=$env(MO_EXPECT_OVMF_VARS)" \
      -drive "file=$env(MO_EXPECT_DISK),format=raw,if=virtio" \
      -boot order=c,menu=off \
      -display none \
      -serial stdio \
      -monitor none \
      -no-reboot \
      -nic user,model=e1000

    expect {
      -re {Please unlock disk[^\r\n]*:} {
        send -- "$env(MO_EXPECT_PASSPHRASE)\r"
        exp_continue
      }
      -re {Enter passphrase[^\r\n]*:} {
        send -- "$env(MO_EXPECT_PASSPHRASE)\r"
        exp_continue
      }
      -re $env(MO_EXPECT_MARKER) {
        set marker_seen 1
        exp_continue
      }
      eof {
        if {$marker_seen == 1} { exit 0 }
        exit 1
      }
      timeout {
        puts stderr "Timed out waiting for encrypted boot marker: $env(MO_EXPECT_MARKER)"
        exit 124
      }
    }
EXPECT
}

truncate -s 12G "$disk"
cp "$ovmf_vars_template" "$install_vars"
: > "$install_log"

echo 'Installing encrypted MO OS through OVMF onto disposable /dev/vda...'
qemu-system-x86_64 \
  -machine q35 \
  -accel tcg,thread=multi \
  -m 2560 \
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
wait_for_poweroff 180

echo 'Booting encrypted installed system and creating a post-snapshot mutation...'
boot_encrypted_disk "$first_boot_vars" "$first_boot_log" "$mutation_marker" "$boot_timeout"
grep -q "$boot_marker" "$first_boot_log" || {
  echo 'Installed boot marker was not observed before mutation.' >&2
  cat "$first_boot_log" >&2
  exit 1
}

echo 'Booting the live ISO in recovery mode and rolling root back to initial...'
cp "$ovmf_vars_template" "$recovery_vars"
: > "$recovery_log"
qemu-system-x86_64 \
  -machine q35 \
  -accel tcg,thread=multi \
  -m 2560 \
  -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
  -drive "if=pflash,format=raw,file=$recovery_vars" \
  -cdrom "$iso_path" \
  -drive "id=mo_recovery_disk,file=$disk,format=raw,if=none" \
  -device virtio-blk-pci,drive=mo_recovery_disk,serial=MO-RECOVERY-VDA-01 \
  -boot order=d,menu=off \
  -display none \
  -serial "file:$recovery_log" \
  -monitor none \
  -no-reboot \
  -nic user,model=e1000 &
qemu_pid=$!

wait_for_marker "$recovery_log" "$recovery_authorization_marker" "$authorization_timeout"
wait_for_marker "$recovery_log" "$rollback_marker" "$recovery_timeout"
wait_for_poweroff 180

echo 'Booting the rolled-back encrypted system with fresh OVMF variables...'
boot_encrypted_disk "$final_boot_vars" "$final_boot_log" "$verified_marker" "$boot_timeout"
grep -q "$boot_marker" "$final_boot_log" || {
  echo 'Installed boot marker was not observed after rollback.' >&2
  cat "$final_boot_log" >&2
  exit 1
}

echo 'MO OS encrypted UEFI installation and rollback test passed.'
