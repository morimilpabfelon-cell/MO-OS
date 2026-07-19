#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v lb >/dev/null 2>&1 || {
  echo "live-build is required. Install package: live-build" >&2
  exit 1
}

if find config/includes.chroot -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  echo 'Python bytecode must not be packaged in the MO OS source tree.' >&2
  exit 1
fi
if find config/includes.chroot -type d -name '__pycache__' -print -quit | grep -q .; then
  echo '__pycache__ directories must not be packaged in MO OS.' >&2
  exit 1
fi

for native_helper in \
  config/includes.chroot/usr/local/libexec/mo-arch-dispatch \
  config/includes.chroot/usr/local/libexec/mo-arch-worker; do
  [[ -f "$native_helper" ]] || {
    echo "Missing MO native helper: $native_helper" >&2
    exit 1
  }
  chmod 0755 "$native_helper"
done

lb config noauto \
  --mode debian \
  --distribution trixie \
  --architectures amd64 \
  --binary-images iso-hybrid \
  --debian-installer none \
  --archive-areas "main contrib non-free-firmware" \
  --security false \
  --apt-recommends false \
  --bootappend-live "boot=live components hostname=mo-os username=mo locales=es_PE.UTF-8 keyboard-layouts=latam systemd.unit=mo-boot-test.target" \
  --iso-application "MO OS Alpha 0.6 Morimil Executor" \
  --iso-publisher "MO OS Project" \
  --iso-volume "MO_OS_ALPHA_06"

bootloader_source=/usr/share/live/build/bootloaders
[[ -d "$bootloader_source" ]] || {
  echo "live-build bootloader templates are missing: $bootloader_source" >&2
  exit 1
}

rm -rf config/bootloaders
cp -a "$bootloader_source" config/bootloaders

isolinux_cfg=config/bootloaders/isolinux/isolinux.cfg
[[ -f "$isolinux_cfg" ]] || {
  echo "Missing isolinux template: $isolinux_cfg" >&2
  exit 1
}
sed -E -i 's/^timeout[[:space:]]+[0-9]+/timeout 50/' "$isolinux_cfg"
grep -q '^timeout 50$' "$isolinux_cfg"

grub_patched=0
while IFS= read -r -d '' grub_cfg; do
  if grep -Eq '^set timeout=' "$grub_cfg"; then
    sed -E -i 's/^set timeout=.*/set timeout=5/' "$grub_cfg"
    grub_patched=1
  fi
done < <(find config/bootloaders/grub-pc -type f -name '*.cfg' -print0)

if [[ "$grub_patched" -eq 0 ]]; then
  printf '\nset timeout=5\n' >> config/bootloaders/grub-pc/grub.cfg
fi
grep -R -q '^set timeout=5$' config/bootloaders/grub-pc

echo "MO OS live-build configuration prepared."
