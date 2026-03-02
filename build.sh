#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$ROOT_DIR/work"
OUT_DIR="$ROOT_DIR/out"
PROFILE_DIR="$WORK_DIR/profile"
OVERLAY_DIR="$ROOT_DIR/overlay"
PAYLOAD_SRC="${PAYLOAD_SRC:-$ROOT_DIR/system-bootstrap}"
RELENG_SRC="${RELENG_SRC:-/usr/share/archiso/configs/releng}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd rsync
need_cmd mkarchiso
need_cmd nproc

if [[ ! -d "$RELENG_SRC" ]]; then
  echo "Releng profile not found: $RELENG_SRC" >&2
  exit 1
fi

if [[ ! -d "$PAYLOAD_SRC" ]]; then
  echo "Payload source not found: $PAYLOAD_SRC" >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"
rm -rf "$WORK_DIR/mkarchiso"
rm -rf "$PROFILE_DIR"
rsync -a --delete "$RELENG_SRC/" "$PROFILE_DIR/"

THREADS="$(nproc)"
export MAKEFLAGS="-j${THREADS}"
export XZ_DEFAULTS="-T0"
export ZSTD_NBTHREADS="${THREADS}"

# Overlay custom scripts into live rootfs.
rsync -a "$OVERLAY_DIR/" "$PROFILE_DIR/"

# Bundle system-bootstrap payload into ISO live environment.
mkdir -p "$PROFILE_DIR/airootfs/root/system-bootstrap"
rsync -a --delete --exclude '.git' "$PAYLOAD_SRC/" "$PROFILE_DIR/airootfs/root/system-bootstrap/"

# Store host pacman config inside payload for chroot restore stage.
mkdir -p "$PROFILE_DIR/airootfs/root/system-bootstrap/pacman-host/pacman.d"
if [[ -f /etc/pacman.conf ]]; then
  cp /etc/pacman.conf "$PROFILE_DIR/airootfs/root/system-bootstrap/pacman-host/pacman.conf"
fi
if [[ -d /etc/pacman.d ]]; then
  rsync -a /etc/pacman.d/ "$PROFILE_DIR/airootfs/root/system-bootstrap/pacman-host/pacman.d/"
fi

# Ensure required runtime packages for deployment script exist in ISO.
cat >> "$PROFILE_DIR/packages.x86_64" <<'PKGS'
arch-install-scripts
git
rsync
btrfs-progs
dosfstools
gptfdisk
grub
efibootmgr
networkmanager
sudo
base-devel
PKGS

chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/deploy-1to1.sh"

# Build ISO.
mkarchiso -v -w "$WORK_DIR/mkarchiso" -o "$OUT_DIR" "$PROFILE_DIR"

echo "ISO build complete. Output: $OUT_DIR"
