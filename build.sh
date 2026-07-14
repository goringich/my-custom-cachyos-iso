#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$ROOT_DIR/work"
OUT_DIR="$ROOT_DIR/out"
PROFILE_DIR="$WORK_DIR/profile"
OVERLAY_DIR="$ROOT_DIR/overlay"
PAYLOAD_SRC="${PAYLOAD_SRC:-$ROOT_DIR/system-bootstrap}"
RELENG_SRC="${RELENG_SRC:-/usr/share/archiso/configs/releng}"
PACMAN_CONFIG_SRC="$ROOT_DIR/config/pacman.conf"

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

if [[ ! -s "$PACMAN_CONFIG_SRC" ]] || grep -Eq '^[[:space:]]*SigLevel[[:space:]]*=[[:space:]]*Never' "$PACMAN_CONFIG_SRC"; then
  echo "A signed, tracked pacman config is required: $PACMAN_CONFIG_SRC" >&2
  exit 1
fi

if [[ -x "$ROOT_DIR/scripts/verify-platform-bridge.sh" ]]; then
  "$ROOT_DIR/scripts/verify-platform-bridge.sh"
fi
if [[ -x "$ROOT_DIR/scripts/verify-postinstall-flow.sh" ]]; then
  "$ROOT_DIR/scripts/verify-postinstall-flow.sh"
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

# Archiso reapplies profiledef.sh file_permissions after copying airootfs.
# Keep the live installer entrypoints executable inside the final SquashFS.
append_profile_permission() {
  local target_path="$1"
  local mode_spec="$2"
  local entry="  [\"$target_path\"]=\"$mode_spec\""

  grep -Fqx "$entry" "$PROFILE_DIR/profiledef.sh" && return 0
  sed -i "\$i\\$entry" "$PROFILE_DIR/profiledef.sh"
}

append_profile_permission "/usr/local/bin/deploy-1to1.sh" "0:0:755"
append_profile_permission "/usr/local/lib/custom-cachyos-iso/post-install-1to1.sh" "0:0:755"

# Bundle system-bootstrap payload into ISO live environment.
mkdir -p "$PROFILE_DIR/airootfs/root/system-bootstrap"
rsync -a --delete --exclude '.git' "$PAYLOAD_SRC/" "$PROFILE_DIR/airootfs/root/system-bootstrap/"

# Bundle an explicit signed package-manager contract. Host pacman configuration
# is intentionally excluded because it may contain unsafe policy or local-only
# mirrors and makes the image non-reproducible.
mkdir -p "$PROFILE_DIR/airootfs/root/system-bootstrap/pacman-host/pacman.d"
install -m 0644 "$PACMAN_CONFIG_SRC" "$PROFILE_DIR/airootfs/root/system-bootstrap/pacman-host/pacman.conf"
for mirrorlist in mirrorlist cachyos-mirrorlist; do
  [[ -s "/etc/pacman.d/$mirrorlist" ]] || {
    echo "Required signed repository mirror list is missing: /etc/pacman.d/$mirrorlist" >&2
    exit 1
  }
  install -m 0644 "/etc/pacman.d/$mirrorlist" "$PROFILE_DIR/airootfs/root/system-bootstrap/pacman-host/pacman.d/$mirrorlist"
done

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
cachyos-keyring
cachyos-mirrorlist
archlinux-keyring
PKGS

chmod +x "$PROFILE_DIR/airootfs/usr/local/bin/deploy-1to1.sh"
chmod +x "$PROFILE_DIR/airootfs/usr/local/lib/custom-cachyos-iso/post-install-1to1.sh"

# Build ISO.
mkarchiso -v -w "$WORK_DIR/mkarchiso" -o "$OUT_DIR" "$PROFILE_DIR"

echo "ISO build complete. Output: $OUT_DIR"
