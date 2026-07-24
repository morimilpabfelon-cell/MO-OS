#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

readme=README.md
executor_doc=docs/MORIMIL-EXECUTOR.md
arch_doc=docs/DEBIAN-ARCH-EXECUTION.md
installed_doc=config/includes.chroot/usr/share/doc/mo-os/MORIMIL-EXECUTOR.md

require_fixed() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || {
    echo "documentation-consistency: missing '$pattern' in $file" >&2
    exit 1
  }
}

for file in "$readme" "$executor_doc" "$arch_doc" "$installed_doc"; do
  [[ -f "$file" && ! -L "$file" ]] || {
    echo "documentation-consistency: invalid documentation file: $file" >&2
    exit 1
  }
done

for invariant in \
  'Morimil decide. Debian gobierna. Arch ejecuta. Android permanece fuera de MO-OS.' \
  '/usr/local/sbin/mo-executord' \
  '/var/lib/mo-bodyd/requests/REQUEST_ID.json' \
  'mo executor recover' \
  'sudo make arch-real-integration-test' \
  'bootstrap Arch `2026.07.01`' \
  'systemd-nspawn' \
  'nsenter'; do
  require_fixed "$invariant" "$readme"
done

for invariant in \
  '/usr/local/sbin/mo-executord' \
  '/var/lib/mo-bodyd/requests/REQUEST_ID.json' \
  'request_execution_outcome_unknown_after_interruption' \
  'MO OS does not claim exactly-once semantics' \
  'does not depend on `machinectl shell`' \
  'The Arch worker is Bash-only' \
  'downloads the pinned Arch bootstrap `2026.07.01`'; do
  require_fixed "$invariant" "$executor_doc"
done

for invariant in \
  'compares `/proc/LEADER/root` with the authorized root by filesystem device and inode' \
  'enters only the leader' \
  'does not use `machinectl shell`' \
  'does not require Python' \
  'runs on every candidate workflow' \
  'does not run `pacman`'; do
  require_fixed "$invariant" "$arch_doc"
done

for invariant in \
  '/usr/local/sbin/mo-executord' \
  '/var/lib/mo-bodyd/requests/REQUEST_ID.json' \
  'never automatically repeats an interrupted accepted operation' \
  'enters fixed namespaces with `nsenter`' \
  'does not require Python or a guest system bus'; do
  require_fixed "$invariant" "$installed_doc"
done

stale_patterns=(
  'CI **todavía no descarga el bootstrap de Arch'
  'A real Arch bootstrap and real `mo-dev` container boot are not yet performed'
  'It does **not** currently download the Arch bootstrap'
  'invokes only `/usr/local/libexec/mo-arch-worker status` through `machinectl`'
  '/var/lib/mo-bodyd/accepted/REQUEST_ID'
)
for stale in "${stale_patterns[@]}"; do
  if grep -R -Fq -- "$stale" "$readme" "$executor_doc" "$arch_doc" "$installed_doc"; then
    echo "documentation-consistency: stale claim remains: $stale" >&2
    exit 1
  fi
done

printf '%s\n' 'MO OS documentation matches durable executor and real Arch validation.'
