#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly machine_name=mo-dev
readonly machine_root=/var/lib/machines/mo-dev
readonly host_dispatch=/usr/local/libexec/mo-arch-dispatch
readonly host_worker=/usr/local/libexec/mo-arch-worker
readonly source_dispatch="$repo_root/config/includes.chroot/usr/local/libexec/mo-arch-dispatch"
readonly source_worker="$repo_root/config/includes.chroot/usr/local/libexec/mo-arch-worker"
readonly worker_inside=/usr/local/libexec/mo-arch-worker
readonly release=2026.07.01
readonly archive="archlinux-bootstrap-${release}-x86_64.tar.zst"
readonly archive_url="https://geo.mirror.pkgbuild.com/iso/${release}/${archive}"
readonly archive_sha256=9cadf82e389427fb61739ad3b0c213b2abd331354fab6460972e4e52bb8ff9e8

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo 'arch-real-integration: root privileges required' >&2
  exit 1
}

for path in "$machine_root" "$host_dispatch" "$host_worker"; do
  [[ ! -e "$path" && ! -L "$path" ]] || {
    echo "arch-real-integration: refusing to overwrite existing path: $path" >&2
    exit 1
  }
done

[[ -f "$source_dispatch" && ! -L "$source_dispatch" ]] || {
  echo 'arch-real-integration: governed dispatcher source is invalid' >&2
  exit 1
}
[[ -f "$source_worker" && ! -L "$source_worker" ]] || {
  echo 'arch-real-integration: governed worker source is invalid' >&2
  exit 1
}

for command_name in \
  curl install machinectl nsenter python3 realpath sha256sum systemd-firstboot \
  systemd-nspawn tar timeout unzstd; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "arch-real-integration: missing dependency: $command_name" >&2
    exit 1
  }
done

workdir="$(mktemp -d)"
nspawn_pid=''
created_machine_root=0
created_dispatch=0
created_worker=0

cleanup() {
  local status=$?
  local cleanup_failed=0
  local cleanup_attempt
  set +e

  if machinectl show "$machine_name" >/dev/null 2>&1; then
    timeout 20 machinectl terminate "$machine_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "$nspawn_pid" ]]; then
    kill "$nspawn_pid" >/dev/null 2>&1 || true
    timeout 20 tail --pid="$nspawn_pid" -f /dev/null >/dev/null 2>&1 || true
    kill -KILL "$nspawn_pid" >/dev/null 2>&1 || true
    wait "$nspawn_pid" >/dev/null 2>&1 || true
  fi

  for ((cleanup_attempt = 0; cleanup_attempt < 20; cleanup_attempt++)); do
    if ! machinectl show "$machine_name" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ((created_machine_root)); then
    rm -rf --one-file-system "$machine_root"
  fi
  if ((created_dispatch)); then
    rm -f "$host_dispatch"
  fi
  if ((created_worker)); then
    rm -f "$host_worker"
  fi
  rmdir /usr/local/libexec >/dev/null 2>&1 || true
  rm -rf "$workdir"

  if machinectl show "$machine_name" >/dev/null 2>&1; then
    echo 'arch-real-integration: cleanup left mo-dev registered' >&2
    cleanup_failed=1
  fi
  for path in "$machine_root" "$host_dispatch" "$host_worker" "$workdir"; do
    if [[ -e "$path" || -L "$path" ]]; then
      echo "arch-real-integration: cleanup left path: $path" >&2
      cleanup_failed=1
    fi
  done
  if ((cleanup_failed)) && ((status == 0)); then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

mkdir -p /usr/local/libexec
install -m0755 "$source_dispatch" "$host_dispatch"
created_dispatch=1
install -m0755 "$source_worker" "$host_worker"
created_worker=1

curl --fail --location --proto '=https' --tlsv1.2 \
  --output "$workdir/$archive" "$archive_url"
printf '%s  %s\n' "$archive_sha256" "$workdir/$archive" | sha256sum --check --status

echo 'arch-real-integration: verified pinned Arch bootstrap'
mkdir -p "$workdir/extract"
tar --use-compress-program=unzstd -xpf "$workdir/$archive" -C "$workdir/extract"
source_root="$workdir/extract/root.x86_64"
[[ -d "$source_root" && ! -L "$source_root" ]] || {
  echo 'arch-real-integration: unexpected bootstrap layout' >&2
  exit 1
}

mkdir -p "$machine_root"
created_machine_root=1
cp -a "$source_root"/. "$machine_root"/
install -Dm0755 "$host_worker" "$machine_root$worker_inside"

read -r host_worker_sha _ < <(sha256sum "$host_worker")
read -r domain_worker_sha _ < <(sha256sum "$machine_root$worker_inside")
[[ "$host_worker_sha" =~ ^[0-9a-f]{64}$ && "$domain_worker_sha" == "$host_worker_sha" ]] || {
  echo 'arch-real-integration: worker installation digest mismatch' >&2
  exit 1
}

systemd-firstboot \
  --root="$machine_root" \
  --hostname="$machine_name" \
  --locale=C.UTF-8 \
  --timezone=UTC \
  --setup-machine-id >/dev/null

systemd-nspawn \
  --quiet \
  --directory="$machine_root" \
  --machine="$machine_name" \
  --boot \
  --register=yes \
  --private-network \
  --settings=no \
  >"$workdir/nspawn.log" 2>&1 &
nspawn_pid=$!

running=0
for ((attempt = 0; attempt < 60; attempt++)); do
  if ! kill -0 "$nspawn_pid" >/dev/null 2>&1; then
    echo 'arch-real-integration: systemd-nspawn exited before Arch became ready' >&2
    sed -n '1,200p' "$workdir/nspawn.log" >&2
    exit 1
  fi
  machine_state="$(machinectl show "$machine_name" --property=State --value 2>/dev/null || true)"
  if [[ "$machine_state" == running ]]; then
    running=1
    break
  fi
  sleep 1
done
((running)) || {
  echo 'arch-real-integration: Arch container did not reach State=running' >&2
  sed -n '1,200p' "$workdir/nspawn.log" >&2
  exit 1
}

if ! "$host_dispatch" status >"$workdir/status.json" 2>"$workdir/dispatch.err"; then
  echo 'arch-real-integration: governed dispatcher failed against real Arch' >&2
  sed -n '1,200p' "$workdir/dispatch.err" >&2
  sed -n '1,200p' "$workdir/nspawn.log" >&2
  exit 1
fi
python3 - "$workdir/status.json" <<'PY_VALIDATE_STATUS'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
value = json.loads(raw.decode("utf-8"))
assert value["schema_version"] == "mo.arch.worker.status.v0.1", value
assert value["domain"] == "arch", value
assert value["machine"] == "x86_64", value
assert value["os_release"]["ID"] == "arch", value
expected = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
assert raw == expected.encode("utf-8"), (raw, expected)
PY_VALIDATE_STATUS

echo '# integrity mutation for negative test' >> "$machine_root$worker_inside"
if "$host_dispatch" status >"$workdir/tampered.out" 2>"$workdir/tampered.err"; then
  echo 'arch-real-integration: modified Arch worker was accepted' >&2
  exit 1
fi
grep -Fxq 'arch_worker_integrity_mismatch' "$workdir/tampered.err" || {
  echo 'arch-real-integration: modified worker failed for the wrong reason' >&2
  sed -n '1,200p' "$workdir/tampered.err" >&2
  exit 1
}

printf '%s\n' 'MO OS real Debian-to-systemd-nspawn-to-Arch integration passed.'
