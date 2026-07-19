#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dispatch="$repo_root/config/includes.chroot/usr/local/libexec/mo-arch-dispatch"
worker="$repo_root/config/includes.chroot/usr/local/libexec/mo-arch-worker"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

machine_root="$workdir/machines/mo-dev"
fake_machinectl="$workdir/fake-machinectl"
mkdir -p "$machine_root/usr/local/libexec"
install -m0755 "$worker" "$machine_root/usr/local/libexec/mo-arch-worker"

cat > "$fake_machinectl" <<'EOF_MACHINECTL'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  start)
    [[ $# -eq 2 && "$2" == mo-dev ]]
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
  *)
    exit 64
    ;;
esac
EOF_MACHINECTL
chmod 0755 "$fake_machinectl"

export MO_ARCH_DISPATCH_ALLOW_TEST_MODE=1
export MO_ARCH_DISPATCH_MACHINE_ROOT="$machine_root"
export MO_ARCH_DISPATCH_MACHINECTL="$fake_machinectl"

status="$($dispatch status)"
python3 - "$status" <<'PY_STATUS'
import json
import sys
status = json.loads(sys.argv[1])
assert status["schema_version"] == "mo.arch.worker.status.v0.1"
assert status["domain"] == "arch"
assert status["os_release"]["ID"] == "arch"
PY_STATUS

if "$dispatch" shell.execute >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted an arbitrary operation.' >&2
  exit 1
fi

FAKE_MACHINECTL_MODE=malformed
export FAKE_MACHINECTL_MODE
if "$dispatch" status >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted malformed Arch evidence.' >&2
  exit 1
fi
unset FAKE_MACHINECTL_MODE

rm -rf "$machine_root"
if "$dispatch" status >/dev/null 2>&1; then
  echo 'Debian dispatcher accepted a missing Arch domain.' >&2
  exit 1
fi

bash -n "$dispatch"
bash -n "$worker"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$dispatch" "$worker" "$0"
fi

printf '%s\n' 'Debian governance and fixed Arch status execution tests passed.'
