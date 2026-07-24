#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dispatch="${MO_TEST_DISPATCH:-$repo_root/config/includes.chroot/usr/local/libexec/mo-arch-dispatch}"
worker="${MO_TEST_WORKER:-$repo_root/config/includes.chroot/usr/local/libexec/mo-arch-worker}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

machine_root="$workdir/machines/mo-dev"
authoritative_worker="$workdir/authoritative/mo-arch-worker"
fake_machinectl="$workdir/fake-machinectl"
fake_nsenter="$workdir/fake-nsenter"
fake_proc_root="$workdir/proc"
leader_pid=4242
leader_directory="$fake_proc_root/$leader_pid"
leader_counter="$workdir/leader-counter"
mkdir -p "$machine_root/usr/local/libexec" "$(dirname "$authoritative_worker")" "$leader_directory"
install -m0755 "$worker" "$authoritative_worker"
install -m0755 "$worker" "$machine_root/usr/local/libexec/mo-arch-worker"
ln -s "$machine_root" "$leader_directory/root"

cat > "$fake_machinectl" <<'EOF_MACHINECTL'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == show && $# -eq 4 ]]
[[ "$2" == mo-dev ]]
[[ "$4" == --value ]]
property=${3#--property=}
case "$property" in
  State)
    if [[ ${FAKE_MACHINECTL_MODE:-valid} == stopped ]]; then
      printf '%s\n' dead
    else
      printf '%s\n' running
    fi
    ;;
  RootDirectory)
    if [[ ${FAKE_MACHINECTL_MODE:-valid} == wrong-root ]]; then
      printf '%s\n' "$FAKE_MACHINE_ROOT-other"
    else
      printf '%s\n' "$FAKE_MACHINE_ROOT"
    fi
    ;;
  Leader)
    if [[ ${FAKE_MACHINECTL_MODE:-valid} == invalid-leader ]]; then
      printf '%s\n' invalid
    elif [[ ${FAKE_MACHINECTL_MODE:-valid} == leader-changes ]]; then
      count=0
      [[ -r "$FAKE_LEADER_COUNTER" ]] && count=$(<"$FAKE_LEADER_COUNTER")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FAKE_LEADER_COUNTER"
      if ((count >= 3)); then
        printf '%s\n' 4243
      else
        printf '%s\n' 4242
      fi
    else
      printf '%s\n' 4242
    fi
    ;;
  *) exit 64 ;;
esac
EOF_MACHINECTL
chmod 0755 "$fake_machinectl"

cat > "$fake_nsenter" <<'EOF_NSENTER'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 13 ]]
[[ "$1" == --target && "$2" == 4242 ]]
[[ "$3" == --mount && "$4" == --uts && "$5" == --ipc ]]
[[ "$6" == --net && "$7" == --pid && "$8" == --cgroup ]]
[[ "$9" == "--root=$FAKE_PROC_ROOT/4242/root" ]]
[[ "${10}" == "--wd=$FAKE_PROC_ROOT/4242/root" ]]
[[ "${11}" == -- ]]
[[ "${12}" == /usr/local/libexec/mo-arch-worker ]]
[[ "${13}" == status ]]
case ${FAKE_NSENTER_MODE:-valid} in
  valid)
    printf '%s\n' '{"domain":"arch","kernel_release":"6.12.0-test","machine":"x86_64","os_release":{"ID":"arch","NAME":"Arch Linux","VERSION_ID":"rolling"},"schema_version":"mo.arch.worker.status.v0.1"}'
    ;;
  malformed) printf '%s\n' not-json ;;
  failed) exit 1 ;;
  *) exit 64 ;;
esac
EOF_NSENTER
chmod 0755 "$fake_nsenter"

export MO_ARCH_DISPATCH_ALLOW_TEST_MODE=1
export MO_ARCH_DISPATCH_MACHINE_ROOT="$machine_root"
export MO_ARCH_DISPATCH_WORKER_HOST="$authoritative_worker"
export MO_ARCH_DISPATCH_MACHINECTL="$fake_machinectl"
export MO_ARCH_DISPATCH_NSENTER="$fake_nsenter"
export MO_ARCH_DISPATCH_PROC_ROOT="$fake_proc_root"
export FAKE_MACHINE_ROOT="$machine_root"
export FAKE_PROC_ROOT="$fake_proc_root"
export FAKE_LEADER_COUNTER="$leader_counter"

status="$(bash "$dispatch" status)"
python3 - "$status" <<'PY_STATUS'
import json
import sys
status = json.loads(sys.argv[1])
assert status["schema_version"] == "mo.arch.worker.status.v0.1"
assert status["domain"] == "arch"
assert status["machine"] == "x86_64"
assert status["os_release"]["ID"] == "arch"
PY_STATUS

if bash "$dispatch" shell.execute >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted an arbitrary operation.' >&2
  exit 1
fi

export FAKE_MACHINECTL_MODE=stopped
if bash "$dispatch" status >"$workdir/stopped.out" 2>"$workdir/stopped.err"; then
  echo 'arch.status started or accepted a stopped Arch domain.' >&2
  exit 1
fi
grep -Fxq arch_domain_not_running "$workdir/stopped.err"
unset FAKE_MACHINECTL_MODE

export FAKE_MACHINECTL_MODE=wrong-root
if bash "$dispatch" status >"$workdir/root.out" 2>"$workdir/root.err"; then
  echo 'Debian dispatcher accepted a registered root mismatch.' >&2
  exit 1
fi
grep -Fxq arch_domain_root_resolution_failed "$workdir/root.err"
unset FAKE_MACHINECTL_MODE

rm "$leader_directory/root"
escaped_root="$workdir/escaped-root"
mkdir -p "$escaped_root"
ln -s "$escaped_root" "$leader_directory/root"
if bash "$dispatch" status >"$workdir/leader-root.out" 2>"$workdir/leader-root.err"; then
  echo 'Debian dispatcher accepted a leader rooted outside mo-dev.' >&2
  exit 1
fi
grep -Fxq arch_domain_leader_root_mismatch "$workdir/leader-root.err"
rm "$leader_directory/root"
ln -s "$machine_root" "$leader_directory/root"

export FAKE_MACHINECTL_MODE=invalid-leader
if bash "$dispatch" status >"$workdir/leader.out" 2>"$workdir/leader.err"; then
  echo 'Debian dispatcher accepted an invalid leader PID.' >&2
  exit 1
fi
grep -Fxq arch_domain_leader_invalid "$workdir/leader.err"
unset FAKE_MACHINECTL_MODE

: > "$leader_counter"
export FAKE_MACHINECTL_MODE=leader-changes
if bash "$dispatch" status >"$workdir/change.out" 2>"$workdir/change.err"; then
  echo 'Debian dispatcher accepted a changing container leader.' >&2
  exit 1
fi
grep -Fxq arch_domain_identity_changed "$workdir/change.err"
unset FAKE_MACHINECTL_MODE

export FAKE_NSENTER_MODE=malformed
if bash "$dispatch" status >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted malformed Arch evidence.' >&2
  exit 1
fi
unset FAKE_NSENTER_MODE

export FAKE_NSENTER_MODE=failed
if bash "$dispatch" status >"$workdir/exec.out" 2>"$workdir/exec.err"; then
  echo 'Debian dispatcher accepted a failed namespace execution.' >&2
  exit 1
fi
grep -Fxq arch_worker_execution_failed "$workdir/exec.err"
unset FAKE_NSENTER_MODE

printf '\n# tampered\n' >> "$machine_root/usr/local/libexec/mo-arch-worker"
if bash "$dispatch" status >"$workdir/tamper.out" 2>"$workdir/tamper.err"; then
  echo 'Debian dispatcher accepted a modified Arch worker.' >&2
  exit 1
fi
grep -Fxq arch_worker_integrity_mismatch "$workdir/tamper.err"
install -m0755 "$worker" "$machine_root/usr/local/libexec/mo-arch-worker"

mkdir -p "$workdir/escaped-worker"
install -m0755 "$worker" "$workdir/escaped-worker/mo-arch-worker"
mv "$machine_root/usr/local/libexec" "$machine_root/usr/local/libexec.real"
ln -s "$workdir/escaped-worker" "$machine_root/usr/local/libexec"
if bash "$dispatch" status >"$workdir/path.out" 2>"$workdir/path.err"; then
  echo 'Debian dispatcher accepted a worker through an intermediate symlink.' >&2
  exit 1
fi
grep -Fxq arch_worker_path_not_canonical "$workdir/path.err"
rm "$machine_root/usr/local/libexec"
mv "$machine_root/usr/local/libexec.real" "$machine_root/usr/local/libexec"

rm -rf "$machine_root"
if bash "$dispatch" status >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted a missing Arch domain.' >&2
  exit 1
fi

bash -n "$dispatch"
bash -n "$worker"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$dispatch" "$worker" "$0"
fi

printf '%s\n' 'Debian governance, machine identity, namespaces, canonical paths and fixed Arch status tests passed.'
