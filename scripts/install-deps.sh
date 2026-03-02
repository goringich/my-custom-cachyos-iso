#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

pacman -Sy --needed --noconfirm archiso rsync git
