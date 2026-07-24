#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

coordinator=config/includes.chroot/usr/local/sbin/mo-executord
coordinator_dir=config/includes.chroot/usr/local/libexec/mo-executord
base_module=$coordinator_dir/mo_executord_base.py
core_module=$coordinator_dir/mo_executord_core.py
state_module=$coordinator_dir/mo_executord_state.py
core=config/includes.chroot/usr/local/sbin/mo-bodyd
service=config/includes.chroot/etc/systemd/system/mo-bodyd.service
command_file=config/includes.chroot/usr/local/bin/mo
recovery_test=tests/executor-recovery.sh
recovery_doc=docs/EXECUTOR-RECOVERY.md
installed_doc=config/includes.chroot/usr/share/doc/mo-os/EXECUTOR-RECOVERY.md
pycache_dir="$(mktemp -d)"
trap 'rm -rf "$pycache_dir"' EXIT

fail() {
  echo "executor-recovery-static: $*" >&2
  exit 1
}

require_fixed() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in $file"
}

for path in \
  "$coordinator" "$base_module" "$core_module" "$state_module" "$core" \
  "$service" "$command_file" "$recovery_test" "$recovery_doc" "$installed_doc"; do
  [[ -f "$path" && ! -L "$path" ]] || fail "missing, non-regular, or linked file: $path"
done

PYTHONPYCACHEPREFIX="$pycache_dir" python3 -m py_compile \
  "$coordinator" "$base_module" "$core_module" "$state_module" "$core"
bash -n "$command_file" "$recovery_test"
cmp -s "$recovery_doc" "$installed_doc" || fail 'installed recovery documentation differs from docs source'

for invariant in \
  'SCHEMA_STATE = "morimil.executor.request-state.v0.1"' \
  'PENDING_STATES = {"accepted", "executing"}' \
  'TERMINAL_STATES = {"completed", "failed"}' \
  'fcntl.LOCK_EX' \
  'getattr(os, "O_NOFOLLOW", 0)' \
  'os.O_EXCL' \
  'os.fsync' \
  'fsync_directory' \
  'executor_core_path_not_canonical' \
  'executor_core_permissions_invalid'; do
  require_fixed "$invariant" "$base_module"
done

for invariant in \
  'SourceFileLoader' \
  'process_bundle(core_layout, pathlib.Path(arguments[2]))' \
  'verify_signature' \
  'validate_request'; do
  require_fixed "$invariant" "$core_module"
done

for invariant in \
  'request_interrupted_after_acceptance' \
  'request_execution_outcome_unknown_after_interruption' \
  'request_state_reconciled_from_receipt' \
  'verify_signature(layout.public_key' \
  'snapshot_bundle' \
  'adopt_staging' \
  'MO_EXECUTORD_TEST_CRASH_AFTER'; do
  require_fixed "$invariant" "$state_module"
done

for invariant in \
  'sys.dont_write_bytecode = True' \
  'libexec/mo-executord' \
  'request_id_conflict' \
  'request_replay_rejected' \
  'return delegate_rejection(layout, incoming)' \
  'commands.add_parser("recover"'; do
  require_fixed "$invariant" "$coordinator"
done

if grep -Eq 'shell[[:space:]]*=[[:space:]]*True|os\.system\(|eval\(' \
  "$coordinator" "$base_module" "$core_module" "$state_module"; then
  fail 'coordinator contains a shell or eval execution path'
fi
if grep -Fq 'shell.execute' "$coordinator" "$base_module" "$core_module" "$state_module"; then
  fail 'coordinator must not expose arbitrary shell execution'
fi
require_fixed 'SUPPORTED_OPERATIONS = {"system.status", "arch.status"}' "$base_module"

for invariant in \
  'ExecStart=/usr/bin/python3 /usr/local/sbin/mo-executord serve' \
  'KillMode=control-group' \
  'NoNewPrivileges=yes' \
  'ProtectSystem=strict' \
  'ReadWritePaths=/var/lib/mo-bodyd'; do
  require_fixed "$invariant" "$service"
done

for invariant in \
  'executor_coordinator=/usr/local/sbin/mo-executord' \
  'mo executor recover' \
  '"$executor_coordinator" recover' \
  'mo-bodyd mo-executord' \
  'mo_executord_base.py mo_executord_core.py mo_executord_state.py'; do
  require_fixed "$invariant" "$command_file"
done

for invariant in \
  'run_crash accepted' \
  'run_crash executing' \
  'run_crash receipt' \
  'request_id_conflict' \
  'Recovery accepted a modified receipt.' \
  'Recovery followed a linked request state.' \
  'Recovery accepted an altered request state.' \
  'status-while-serving.json' \
  'req-serve-recovery' \
  'openssl pkeyutl -verify -pubin' \
  'pending_requests"] == 0'; do
  require_fixed "$invariant" "$recovery_test"
done

require_fixed '@bash tests/recovery-static-checks.sh' Makefile
require_fixed '@bash tests/executor-recovery.sh' Makefile
require_fixed 'executor-recovery-test:' Makefile

if find config/includes.chroot -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  fail 'Python bytecode exists in the ISO source tree'
fi
if find config/includes.chroot -type d -name '__pycache__' -print -quit | grep -q .; then
  fail '__pycache__ exists in the ISO source tree'
fi

printf '%s\n' 'MO OS executor durable recovery invariants passed.'
