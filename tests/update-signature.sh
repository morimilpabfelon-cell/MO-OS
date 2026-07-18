#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
update_script="$repo_root/config/includes.chroot/usr/local/sbin/mo-update"
workdir="$(mktemp -d)"
loop_device=''
root_mount="$workdir/root"
top_mount="$workdir/top"

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  set +e
  mountpoint -q "$root_mount/.snapshots" && umount "$root_mount/.snapshots"
  mountpoint -q "$root_mount" && umount "$root_mount"
  mountpoint -q "$top_mount" && umount "$top_mount"
  [[ -n "$loop_device" ]] && losetup -d "$loop_device" 2>/dev/null
  rm -rf "$workdir"
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo 'update-signature.sh must run as root because it mounts a disposable Btrfs image.' >&2
  exit 1
}

for command_name in btrfs losetup mkfs.btrfs mount openssl sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing update-test dependency: $command_name" >&2
    exit 1
  }
done

mkdir -p "$root_mount" "$top_mount" "$workdir/keys" "$workdir/bundle" "$workdir/payload/etc"
truncate -s 512M "$workdir/root.img"
loop_device="$(losetup --find --show "$workdir/root.img")"
mkfs.btrfs -f -L MO_UPDATE_TEST "$loop_device" >/dev/null
mount "$loop_device" "$top_mount"
btrfs subvolume create "$top_mount/@" >/dev/null
btrfs subvolume create "$top_mount/@snapshots" >/dev/null
umount "$top_mount"
mount -o subvol=@ "$loop_device" "$root_mount"
mkdir -p "$root_mount/.snapshots" "$root_mount/etc"
mount -o subvol=@snapshots "$loop_device" "$root_mount/.snapshots"
printf '%s\n' 'MO_INSTALLATION=virtual-uefi-encrypted-alpha' > "$root_mount/etc/mo-installed"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out "$workdir/keys/update-private.pem" >/dev/null 2>&1
openssl pkey -in "$workdir/keys/update-private.pem" -pubout \
  -out "$workdir/keys/update-public.pem" >/dev/null 2>&1

printf '%s\n' '0.5.0-alpha.test' > "$workdir/payload/etc/mo-update-version"
tar -C "$workdir/payload" -cf "$workdir/bundle/payload.tar" etc/mo-update-version
payload_sha="$(sha256sum "$workdir/bundle/payload.tar" | awk '{print $1}')"
cat > "$workdir/bundle/manifest.env" <<MANIFEST
MO_UPDATE_FORMAT=1
MO_UPDATE_VERSION=0.5.0-alpha.test
MO_UPDATE_SEQUENCE=1
MO_UPDATE_PAYLOAD=payload.tar
MO_UPDATE_SHA256=$payload_sha
MANIFEST
openssl dgst -sha256 -sign "$workdir/keys/update-private.pem" \
  -out "$workdir/bundle/manifest.sig" "$workdir/bundle/manifest.env"

/bin/bash "$update_script" verify \
  --bundle "$workdir/bundle" \
  --trust-key "$workdir/keys/update-public.pem" \
  | grep -Fxq 'MO_OS_UPDATE_VERIFIED'

MO_UPDATE_ALLOW_TEST_ROOT=1 /bin/bash "$update_script" apply \
  --root "$root_mount" \
  --bundle "$workdir/bundle" \
  --trust-key "$workdir/keys/update-public.pem" \
  | grep -q 'MO_OS_UPDATE_APPLIED version=0.5.0-alpha.test sequence=1'

grep -Fxq '0.5.0-alpha.test' "$root_mount/etc/mo-update-version"
grep -Fxq '1' "$root_mount/var/lib/mo-update/sequence"
btrfs subvolume show "$root_mount/.snapshots/pre-update-1" >/dev/null

if MO_UPDATE_ALLOW_TEST_ROOT=1 /bin/bash "$update_script" apply \
  --root "$root_mount" \
  --bundle "$workdir/bundle" \
  --trust-key "$workdir/keys/update-public.pem" >/dev/null 2>&1; then
  echo 'Replay protection failed: the same sequence was accepted twice.' >&2
  exit 1
fi

printf '%s\n' 'tampered' >> "$workdir/bundle/payload.tar"
if /bin/bash "$update_script" verify \
  --bundle "$workdir/bundle" \
  --trust-key "$workdir/keys/update-public.pem" >/dev/null 2>&1; then
  echo 'Tampered payload was accepted.' >&2
  exit 1
fi

echo 'MO OS signed update, snapshot and anti-replay test passed.'
