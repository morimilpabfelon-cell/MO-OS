#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

iso_path="${1:-artifacts/mo-os-alpha-0.6-amd64.iso}"
checksum_file="${iso_path}.sha256"

[[ -f "$iso_path" && ! -L "$iso_path" ]] || {
  echo "ISO not found or not a regular file: $iso_path" >&2
  exit 1
}
[[ -f "$checksum_file" && ! -L "$checksum_file" ]] || {
  echo "Checksum file not found or not regular: $checksum_file" >&2
  exit 1
}

for command_name in sha256sum xorriso; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing ISO verification dependency: $command_name" >&2
    exit 1
  }
done

mapfile -t checksum_lines < "$checksum_file"
((${#checksum_lines[@]} == 1)) || {
  echo 'Checksum file must contain exactly one line.' >&2
  exit 1
}
read -r expected_hash recorded_path extra <<< "${checksum_lines[0]}"
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ && -n "$recorded_path" && -z "$extra" ]] || {
  echo 'Checksum file format is invalid.' >&2
  exit 1
}
actual_hash="$(sha256sum "$iso_path")"
actual_hash=${actual_hash%% *}
[[ "$actual_hash" == "$expected_hash" ]] || {
  echo "ISO checksum mismatch: expected=$expected_hash actual=$actual_hash" >&2
  exit 1
}

metadata="$(xorriso -indev "$iso_path" -pvd_info 2>&1)"
for required_metadata in \
  'MO_OS_ALPHA_06' \
  'MO OS Alpha 0.6 Morimil Executor' \
  'MO OS Project'; do
  grep -Fq "$required_metadata" <<< "$metadata" || {
    echo "ISO metadata is missing: $required_metadata" >&2
    exit 1
  }
done

printf 'ISO_SHA256=%s\n' "$actual_hash"
printf '%s\n' "$metadata"
