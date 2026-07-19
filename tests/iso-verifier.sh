#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/build/verify-iso.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

iso="$workdir/mo-os-alpha-0.6-amd64.iso"
fake_bin="$workdir/bin"
mkdir -p "$fake_bin"
printf '%s\n' 'MO OS ISO verifier fixture' > "$iso"

cat > "$fake_bin/xorriso" <<'EOF_XORRISO'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${FAKE_XORRISO_MODE:-valid} == missing-metadata ]]; then
  printf '%s\n' 'Volume id: WRONG_VOLUME'
else
  cat <<'EOF_METADATA'
Volume id    : 'MO_OS_ALPHA_06'
Application  : 'MO OS Alpha 0.6 Morimil Executor'
Publisher    : 'MO OS Project'
EOF_METADATA
fi
EOF_XORRISO
chmod 0755 "$fake_bin/xorriso"
export PATH="$fake_bin:$PATH"

write_valid_checksum() {
  sha256sum "$iso" > "${iso}.sha256"
}

write_valid_checksum
bash "$verifier" "$iso" > "$workdir/valid.out"
grep -Fq 'ISO_SHA256=' "$workdir/valid.out"

good_hash="$(sha256sum "$iso")"
good_hash=${good_hash%% *}
printf '%064d  %s\n' 0 "$iso" > "${iso}.sha256"
if bash "$verifier" "$iso" >"$workdir/hash.out" 2>"$workdir/hash.err"; then
  echo 'ISO verifier accepted an incorrect stored hash.' >&2
  exit 1
fi
grep -Fq 'ISO checksum mismatch' "$workdir/hash.err"

printf '%s  %s\n' "$good_hash" "$workdir/other.iso" > "${iso}.sha256"
if bash "$verifier" "$iso" >"$workdir/path.out" 2>"$workdir/path.err"; then
  echo 'ISO verifier accepted a checksum for another path.' >&2
  exit 1
fi
grep -Fq 'Checksum file path mismatch' "$workdir/path.err"

write_valid_checksum
FAKE_XORRISO_MODE=missing-metadata
export FAKE_XORRISO_MODE
if bash "$verifier" "$iso" >"$workdir/metadata.out" 2>"$workdir/metadata.err"; then
  echo 'ISO verifier accepted missing required metadata.' >&2
  exit 1
fi
grep -Fq 'ISO metadata is missing' "$workdir/metadata.err"
unset FAKE_XORRISO_MODE

printf '%s\n' 'ISO checksum path, digest and metadata rejection tests passed.'
