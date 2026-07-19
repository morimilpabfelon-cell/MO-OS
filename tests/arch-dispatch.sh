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
mkdir -p "$machine_root/usr/local/libexec" "$(dirname "$authoritative_worker")"
install -m0755 "$worker" "$authoritative_worker"
install -m0755 "$worker" "$machine_root/usr/local/libexec/mo-arch-worker"

cat > "$fake_machinectl" <<'EOF_MACHINECTL'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  show)
    [[ $# -eq 4 ]]
    [[ "$2" == mo-dev ]]
    [[ "$3" == --property=State ]]
    [[ "$4" == --value ]]
    if [[ ${FAKE_MACHINECTL_MODE:-valid} == stopped ]]; then
      printf '%s\n' 'dead'
    else
      printf '%s\n' 'running'
    fi
    ;;
  shell)
    [[ $# -eq 5 ]]
    [[ "$2" == --quiet ]]
    [[ "$3" == root@mo-dev ]]
    [[ "$4" == /usr/local/libexec/mo-arch-worker ]]
    [[ "$5" == status ]]
    if [[ ${FAKE_MACHINECTL_MODE:-valid} == malformed ]]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"domain":"arch","kernel_release":"6.12.0-test","machine":"x86_64","os_release":{"ID":"arch","NAME":"Arch Linux","VERSION_ID":"rolling"},"schema_version":"mo.arch.worker.status.v0.1"}'
    fi
    ;;
  *) exit 64 ;;
esac
EOF_MACHINECTL
chmod 0755 "$fake_machinectl"

export MO_ARCH_DISPATCH_ALLOW_TEST_MODE=1
export MO_ARCH_DISPATCH_MACHINE_ROOT="$machine_root"
export MO_ARCH_DISPATCH_WORKER_HOST="$authoritative_worker"
export MO_ARCH_DISPATCH_MACHINECTL="$fake_machinectl"

status="$(bash "$dispatch" status)"
python3 - "$status" <<'PY_STATUS'
import json
import sys
status = json.loads(sys.argv[1])
assert status["schema_version"] == "mo.arch.worker.status.v0.1"
assert status["domain"] == "arch"
assert status["os_release"]["ID"] == "arch"
PY_STATUS

if bash "$dispatch" shell.execute >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted an arbitrary operation.' >&2
  exit 1
fi

FAKE_MACHINECTL_MODE=stopped
export FAKE_MACHINECTL_MODE
if bash "$dispatch" status >"$workdir/stopped.out" 2>"$workdir/stopped.err"; then
  echo 'arch.status started or accepted a stopped Arch domain.' >&2
  exit 1
fi
grep -Fq 'arch_domain_not_running' "$workdir/stopped.err"
unset FAKE_MACHINECTL_MODE

FAKE_MACHINECTL_MODE=malformed
export FAKE_MACHINECTL_MODE
if bash "$dispatch" status >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted malformed Arch evidence.' >&2
  exit 1
fi
unset FAKE_MACHINECTL_MODE

printf '\n# tampered\n' >> "$machine_root/usr/local/libexec/mo-arch-worker"
if bash "$dispatch" status >"$workdir/tamper.out" 2>"$workdir/tamper.err"; then
  echo 'Debian dispatcher accepted a modified Arch worker.' >&2
  exit 1
fi
grep -Fq 'arch_worker_integrity_mismatch' "$workdir/tamper.err"
install -m0755 "$worker" "$machine_root/usr/local/libexec/mo-arch-worker"

mkdir -p "$workdir/escaped-worker"
install -m0755 "$worker" "$workdir/escaped-worker/mo-arch-worker"
mv "$machine_root/usr/local/libexec" "$machine_root/usr/local/libexec.real"
ln -s "$workdir/escaped-worker" "$machine_root/usr/local/libexec"
if bash "$dispatch" status >"$workdir/path.out" 2>"$workdir/path.err"; then
  echo 'Debian dispatcher accepted a worker through an intermediate symlink.' >&2
  exit 1
fi
grep -Fq 'arch_worker_path_not_canonical' "$workdir/path.err"
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

printf '%s\n' 'Debian governance, running-state, canonical paths and fixed Arch status execution tests passed.'
