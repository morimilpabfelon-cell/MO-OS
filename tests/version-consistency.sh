#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  echo "version-consistency: $*" >&2
  exit 1
}

read_release_version() {
  local path=$1 key value
  [[ -r "$path" ]] || fail "missing release file: $path"
  while IFS='=' read -r key value; do
    [[ "$key" == VERSION ]] || continue
    value=${value#\"}
    value=${value%\"}
    printf '%s\n' "$value"
    return 0
  done < "$path"
  fail "VERSION is missing from $path"
}

version="$(<VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]] || \
  fail "invalid VERSION: $version"
release_version="$(read_release_version config/includes.chroot/etc/mo-release)"
[[ "$release_version" == "$version" ]] || \
  fail "VERSION and /etc/mo-release disagree: $version != $release_version"

version_core=${version%%-*}
IFS=. read -r version_major version_minor version_patch version_extra <<< "$version_core"
[[ "$version_major" =~ ^[0-9]+$ && "$version_minor" =~ ^[0-9]+$ && "$version_patch" =~ ^[0-9]+$ && -z "$version_extra" ]] || \
  fail "invalid semantic version core: $version_core"
major_minor="${version_major}.${version_minor}"
iso_relative="artifacts/mo-os-alpha-${major_minor}-amd64.iso"
ci_passphrase="mo-os-${version}-ci-only"

require_fixed() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in $file"
}

require_fixed "ISO := $iso_relative" Makefile
require_fixed "$iso_relative" build/build-iso.sh
require_fixed "$iso_relative" build/verify-iso.sh
require_fixed "$iso_relative" .github/workflows/boot-candidate.yml
require_fixed 'mo_version="$(<"$repo_root/VERSION")"' tests/boot-qemu.sh
require_fixed 'mo_version="$(<"$repo_root/VERSION")"' tests/secure-boot-qemu.sh
require_fixed 'mo_version="$(<"$repo_root/VERSION")"' tests/install-qemu.sh
require_fixed 'ci_passphrase="mo-os-${mo_version}-ci-only"' tests/install-qemu.sh
require_fixed 'release_file=/etc/mo-release' config/includes.chroot/usr/local/sbin/mo-install
require_fixed 'MO_INSTALLER_VERSION=$mo_version' config/includes.chroot/usr/local/sbin/mo-install
require_fixed 'release_file=/etc/mo-release' config/includes.chroot/usr/local/sbin/mo-recovery
require_fixed 'ci_passphrase="mo-os-${mo_version}-ci-only"' config/includes.chroot/usr/local/sbin/mo-install-autotest
require_fixed "readonly ci_passphrase='$ci_passphrase'" config/includes.chroot/usr/local/sbin/mo-recovery-autotest
require_fixed 'exec sudo /usr/bin/python3 /usr/local/sbin/mo-bodyd status' config/includes.chroot/usr/local/bin/mo

if grep -R -nE \
  --exclude=version-consistency.sh \
  --exclude=static-checks.sh \
  '(Alpha 0\.(2|4|5)|mo-os-alpha-0\.(2|4|5)|0\.4\.0-alpha\.1|0\.5\.0-alpha\.2)' \
  Makefile build tests config/includes.chroot .github/workflows; then
  fail 'stale operational Alpha version references remain'
fi

if find config/includes.chroot -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  fail 'Python bytecode exists in the ISO source tree'
fi
if find config/includes.chroot -type d -name '__pycache__' -print -quit | grep -q .; then
  fail '__pycache__ exists in the ISO source tree'
fi

printf 'MO OS version consistency passed: version=%s iso=%s\n' "$version" "$iso_relative"
