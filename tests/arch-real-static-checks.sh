#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

test_script=tests/arch-real-integration.sh
dispatch=config/includes.chroot/usr/local/libexec/mo-arch-dispatch
worker=config/includes.chroot/usr/local/libexec/mo-arch-worker
mo_command=config/includes.chroot/usr/local/bin/mo
workflow=.github/workflows/boot-candidate.yml

require_fixed() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || {
    echo "arch-real-static: missing '$pattern' in $file" >&2
    exit 1
  }
}

[[ -f "$test_script" && ! -L "$test_script" ]] || {
  echo 'arch-real-static: integration test must be a regular repository file' >&2
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
  'curl grep install machinectl nsenter python3 realpath sha256sum stat systemd-firstboot' \
  'machinectl list --no-legend --no-pager' \
  'refusing existing registered machine' \
  '--machine="$machine_name"' \
  '--boot' \
  '--register=yes' \
  '--private-network' \
  '--settings=no' \
  'machinectl show "$machine_name" --property=State --value' \
  'value["domain"] == "arch"' \
  'value["machine"] == "x86_64"' \
  'value["os_release"]["ID"] == "arch"' \
  'arch_worker_integrity_mismatch' \
  'machinectl terminate "$machine_name"' \
  'tail --pid="$nspawn_pid"' \
  'kill -TERM "$nspawn_pid"' \
  'kill -KILL "$nspawn_pid"' \
  'cleanup_attempt < 20' \
  'rm -rf --one-file-system "$machine_root"' \
  'cleanup left mo-dev registered' \
  'cleanup left path' \
  'refusing to overwrite existing path'; do
  require_fixed "$invariant" "$test_script"
done

for invariant in \
  'nsenter_cmd=/usr/bin/nsenter' \
  'stat_cmd=/usr/bin/stat' \
  '--property=RootDirectory' \
  '--property=Leader' \
  "-Lc '%d:%i'" \
  'machine_root_identity' \
  'leader_root_identity' \
  '--mount --uts --ipc --net --pid --cgroup' \
  '--root="$leader_root"' \
  '--wd="$leader_root"' \
  'arch_domain_leader_root_mismatch' \
  'arch_domain_identity_changed'; do
  require_fixed "$invariant" "$dispatch"
done

for invariant in \
  'readonly os_release_path=/usr/lib/os-release' \
  'readonly uname_cmd=/usr/bin/uname' \
  'normalize_os_release_value' \
  'arch_os_release_duplicate_field' \
  'arch_identity_mismatch' \
  'VERSION_ID":"%s' \
  'mo.arch.worker.status.v0.1'; do
  require_fixed "$invariant" "$worker"
done
if grep -Fq 'python3' "$worker"; then
  echo 'arch-real-static: fixed Arch worker must not depend on Python' >&2
  exit 1
fi

require_fixed 'mount nsenter openssl' "$mo_command"
require_fixed 'sha256sum stat systemctl' "$mo_command"

if grep -Eq '(^|[[:space:]/])pacman([[:space:]]|$)' "$test_script"; then
  echo 'arch-real-static: real integration test must not invoke pacman' >&2
  exit 1
fi
if grep -Fq 'MO_ARCH_DISPATCH_ALLOW_TEST_MODE' "$test_script"; then
  echo 'arch-real-static: real integration test must not enable dispatcher test mode' >&2
  exit 1
fi
if grep -Fq '"$machinectl_cmd" shell' "$dispatch"; then
  echo 'arch-real-static: dispatcher must not depend on an Arch system bus or machinectl shell' >&2
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
