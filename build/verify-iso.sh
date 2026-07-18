#!/usr/bin/env bash
set -Eeuo pipefail

iso_path="${1:-artifacts/mo-os-alpha-0.3-amd64.iso}"

[[ -f "$iso_path" ]] || {
  echo "ISO not found: $iso_path" >&2
  exit 1
}

command -v xorriso >/dev/null 2>&1 || {
  echo "xorriso is required to inspect the image." >&2
  exit 1
}

sha256sum "$iso_path"
xorriso -indev "$iso_path" -pvd_info
