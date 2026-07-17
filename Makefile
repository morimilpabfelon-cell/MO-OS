.PHONY: help check configure iso verify run clean

SHELL := /bin/bash
ISO := artifacts/mo-os-alpha-0.1-amd64.iso

help:
	@printf '%s\n' \
	  'MO OS build commands' \
	  '  make check      Static validation' \
	  '  make configure  Generate live-build state' \
	  '  sudo make iso   Build the bootable ISO' \
	  '  make verify     Inspect and hash the ISO' \
	  '  make run        Boot the ISO with QEMU' \
	  '  sudo make clean Remove live-build output'

check:
	@bash tests/static-checks.sh

configure:
	@bash build/configure.sh

iso:
	@bash build/build-iso.sh

verify:
	@bash build/verify-iso.sh "$(ISO)"

run:
	@test -f "$(ISO)" || { echo "Missing $(ISO). Build it first." >&2; exit 1; }
	@command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 is required.' >&2; exit 1; }
	@qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -cdrom "$(ISO)" -boot d

clean:
	@lb clean --binary --chroot || true
	@rm -rf .build artifacts
