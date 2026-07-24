#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

test_script=tests/arch-real-integration.sh
workflow=.github/workflows/boot-candidate.yml

require_fixed() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || {
    echo "arch-real-static: missing '$pattern' in $file" >&2
    exit 1
  }
}

[[ -x "$test_script" ]] || {
  echo 'arch-real-static: integration test must be executable' >&2
  exit 1
}

for invariant in \
  'readonly machine_name=mo-dev' \
  'readonly machine_root=/var/lib/machines/mo-dev' \
  'readonly host_dispatch=/usr/local/libexec/mo-arch-dispatch' \
  'readonly host_worker=/usr/local/libexec/mo-arch-worker' \
  'readonly release=2026.07.01' \
  'readonly archive_sha256=9cadf82e389427fb61739ad3b0c213b2abd331354fab6460972e4e52bb8ff9e8' \
  "--proto '=https'" \
  'sha256sum --check --status' \
  '--machine="$machine_name"' \
  '--boot' \
  '--register=yes' \
  '--private-network' \
  '--settings=no' \
  'machinectl show "$machine_name" --property=State --value' \
  'status_json="$($host_dispatch status)"' \
  'value["domain"] == "arch"' \
  'value["os_release"]["ID"] == "arch"' \
  'arch_worker_integrity_mismatch' \
  'machinectl terminate "$machine_name"' \
  'rm -rf --one-file-system "$machine_root"' \
  'refusing to overwrite existing path'; do
  require_fixed "$invariant" "$test_script"
done

if grep -Eq '(^|[[:space:]/])pacman([[:space:]]|$)' "$test_script"; then
  echo 'arch-real-static: real integration test must not invoke pacman' >&2
  exit 1
fi
if grep -Fq 'MO_ARCH_DISPATCH_ALLOW_TEST_MODE' "$test_script"; then
  echo 'arch-real-static: real integration test must not enable dispatcher test mode' >&2
  exit 1
fi
if grep -Eq 'machinectl[[:space:]]+shell.*(bash|sh)([[:space:]]|$)' "$test_script"; then
  echo 'arch-real-static: arbitrary shell invocation inside Arch is forbidden' >&2
  exit 1
fi

for invariant in \
  'systemd-container' 'zstd' 'curl' \
  'make arch-real-integration-test' \
  'diagnostics/real-arch-integration.log'; do
  require_fixed "$invariant" "$workflow"
done

require_fixed 'arch-real-static-checks.sh' Makefile
require_fixed 'arch-real-integration-test:' Makefile
require_fixed 'tests/arch-real-integration.sh' Makefile

printf '%s\n' 'MO OS real Arch integration invariants passed.'
