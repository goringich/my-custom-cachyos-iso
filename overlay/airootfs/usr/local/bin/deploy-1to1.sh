#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  deploy-1to1.sh --disk <device> --hostname <name> --user <name> [options]

Required:
  --disk            Target disk (e.g. /dev/nvme0n1)
  --hostname        New hostname
  --user            Username to create

Optional:
  --timezone        Timezone (default: Europe/Moscow)
  --locale          Locale without suffix (default: ru_RU)
  --keymap          Console keymap (default: ru)
  --user-password   Initial user password (default: changeme)
  --root-password   Initial root password (default: changeme)

WARNING: selected disk will be fully erased.
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

part_path() {
  local disk="$1"
  local n="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p${n}"
  else
    echo "${disk}${n}"
  fi
}

DISK=""
HOSTNAME=""
USERNAME=""
TIMEZONE="Europe/Moscow"
LOCALE="ru_RU"
KEYMAP="ru"
USER_PASSWORD="changeme"
ROOT_PASSWORD="changeme"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --user) USERNAME="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --locale) LOCALE="$2"; shift 2 ;;
    --keymap) KEYMAP="$2"; shift 2 ;;
    --user-password) USER_PASSWORD="$2"; shift 2 ;;
    --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "$DISK" && -n "$HOSTNAME" && -n "$USERNAME" ]] || {
  usage
  exit 1
}

[[ -b "$DISK" ]] || {
  echo "Disk not found: $DISK" >&2
  exit 1
}

for cmd in sgdisk mkfs.fat mkfs.btrfs mount umount pacstrap genfstab arch-chroot rsync awk sed chpasswd; do
  need_cmd "$cmd"
done

PAYLOAD_DIR="/root/system-bootstrap"
if [[ ! -d "$PAYLOAD_DIR/manifests" ]]; then
  echo "Payload missing at $PAYLOAD_DIR" >&2
  exit 1
fi

printf 'Type exactly YES to continue and wipe %s: ' "$DISK"
read -r confirm
[[ "$confirm" == "YES" ]] || {
  echo "Aborted"
  exit 1
}

EFI_PART="$(part_path "$DISK" 1)"
ROOT_PART="$(part_path "$DISK" 2)"

umount -R /mnt 2>/dev/null || true

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:ROOT "$DISK"

mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"

mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,var,.snapshots,efi}
mount -o subvol=@home "$ROOT_PART" /mnt/home
mount -o subvol=@var "$ROOT_PART" /mnt/var
mount -o subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/efi

pacstrap -K /mnt base linux linux-firmware sudo vim git rsync btrfs-progs grub efibootmgr networkmanager base-devel

genfstab -U /mnt >> /mnt/etc/fstab

mkdir -p /mnt/root/system-bootstrap
rsync -a --delete "$PAYLOAD_DIR/" /mnt/root/system-bootstrap/

cat > /mnt/root/post-install-1to1.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="$1"
USERNAME="$2"
TIMEZONE="$3"
LOCALE="$4"
KEYMAP="$5"
ROOT_PASSWORD="$6"
USER_PASSWORD="$7"

log() { printf '[post] %s\n' "$*"; }

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

if ! grep -q "^${LOCALE}\.UTF-8 UTF-8" /etc/locale.gen; then
  echo "${LOCALE}.UTF-8 UTF-8" >> /etc/locale.gen
else
  sed -i "s/^#\(${LOCALE}\.UTF-8 UTF-8\)/\1/" /etc/locale.gen
fi
locale-gen

echo "LANG=${LOCALE}.UTF-8" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$USERNAME"
fi

echo "root:${ROOT_PASSWORD}" | chpasswd
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

systemctl enable NetworkManager

# Reuse source-machine pacman repo setup (Cachy mirrors, custom includes), if bundled.
if [[ -f /root/system-bootstrap/pacman-host/pacman.conf ]]; then
  log "Applying bundled pacman repo config"
  cp /root/system-bootstrap/pacman-host/pacman.conf /etc/pacman.conf
fi
if [[ -d /root/system-bootstrap/pacman-host/pacman.d ]]; then
  mkdir -p /etc/pacman.d
  rsync -a /root/system-bootstrap/pacman-host/pacman.d/ /etc/pacman.d/
fi

# Try to install package manifest; skip packages unavailable in current repos.
if [[ -s /root/system-bootstrap/manifests/pacman-explicit-non-system.txt ]]; then
  log "Installing repo package manifest"
  pacman -Syu --noconfirm
  mapfile -t wanted < /root/system-bootstrap/manifests/pacman-explicit-non-system.txt
  install_list=()
  for pkg in "${wanted[@]}"; do
    [[ -n "$pkg" ]] || continue
    if pacman -Si "$pkg" >/dev/null 2>&1; then
      install_list+=("$pkg")
    else
      log "Skipping unavailable repo package: $pkg"
    fi
  done
  if [[ "${#install_list[@]}" -gt 0 ]]; then
    pacman -S --needed --noconfirm "${install_list[@]}"
  fi
fi

if [[ -d /root/system-bootstrap/home ]]; then
  log "Restoring home snapshot"
  rsync -a /root/system-bootstrap/home/ "/home/${USERNAME}/"
  chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"
fi

if [[ -s /root/system-bootstrap/manifests/enabled-services.txt ]]; then
  log "Enabling captured services"
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    systemctl enable "$svc" || log "Service enable skipped: $svc"
  done < /root/system-bootstrap/manifests/enabled-services.txt
fi

log "Installing GRUB"
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=CachyCustom
grub-mkconfig -o /boot/grub/grub.cfg

if [[ -s /root/system-bootstrap/manifests/aur-explicit.txt ]]; then
  log "Installing AUR packages via yay"
  runuser -u "$USERNAME" -- bash -lc '
    set -euo pipefail
    jobs="$(nproc)"
    export MAKEFLAGS="-j${jobs}"
    export CMAKE_BUILD_PARALLEL_LEVEL="${jobs}"
    export XZ_DEFAULTS="-T0"
    export ZSTD_NBTHREADS="${jobs}"
    tmp_dir="$(mktemp -d)"
    trap "rm -rf \"$tmp_dir\"" EXIT
    if ! command -v yay >/dev/null 2>&1; then
      git clone https://aur.archlinux.org/yay.git "$tmp_dir/yay"
      cd "$tmp_dir/yay"
      makepkg -si --noconfirm
      cd /
    fi
    mapfile -t aur_list < /root/system-bootstrap/manifests/aur-explicit.txt
    if [[ "${#aur_list[@]}" -gt 0 ]]; then
      yay -S --needed --noconfirm "${aur_list[@]}"
    fi
  ' || log "AUR stage failed; continue and fix after first boot"
fi

log "Post-install completed"
CHROOT_SCRIPT

chmod +x /mnt/root/post-install-1to1.sh
arch-chroot /mnt /root/post-install-1to1.sh "$HOSTNAME" "$USERNAME" "$TIMEZONE" "$LOCALE" "$KEYMAP" "$ROOT_PASSWORD" "$USER_PASSWORD"

rm -f /mnt/root/post-install-1to1.sh
sync

echo
echo "Installation complete. You can reboot now."
echo "Remember to change default passwords immediately."
