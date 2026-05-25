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
  --dry-run         Validate inputs and print the install plan without touching the disk

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
DRY_RUN=0

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
    --dry-run) DRY_RUN=1; shift ;;
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

for required in \
  "$PAYLOAD_DIR/scripts/install-all.sh" \
  "$PAYLOAD_DIR/scripts/restore-audit.sh" \
  "$PAYLOAD_DIR/scripts/clone-repos.sh" \
  "$PAYLOAD_DIR/manifests/enabled-system-units.txt" \
  "/usr/local/lib/custom-cachyos-iso/post-install-1to1.sh"; do
  if [[ ! -e "$required" ]]; then
    echo "Required shared payload file is missing: $required" >&2
    exit 1
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
Dry-run install plan

Disk: $DISK
EFI partition: $(part_path "$DISK" 1)
Root partition: $(part_path "$DISK" 2)
Hostname: $HOSTNAME
User: $USERNAME
Timezone: $TIMEZONE
Locale: $LOCALE
Keymap: $KEYMAP
Payload: $PAYLOAD_DIR

Planned filesystem layout:
- GPT partition table
- 1 GiB EFI FAT32 partition
- Btrfs root partition
- subvolumes: @, @home, @var, @snapshots

Planned bootstrap flow:
1. wipe target disk
2. create EFI + ROOT partitions
3. pacstrap base system
4. copy bundled system-bootstrap payload
5. apply shared system-bootstrap restore layer inside target system
6. hydrate repositories from configs/repos.txt
7. install codex-orchestrator if present
8. install first-boot retry + shared restore audit
9. install GRUB and finish bring-up
EOF
  exit 0
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
install -D -m 0755 /usr/local/lib/custom-cachyos-iso/post-install-1to1.sh /mnt/root/post-install-1to1.sh
arch-chroot /mnt /root/post-install-1to1.sh "$HOSTNAME" "$USERNAME" "$TIMEZONE" "$LOCALE" "$KEYMAP" "$ROOT_PASSWORD" "$USER_PASSWORD"

rm -f /mnt/root/post-install-1to1.sh
sync

echo
echo "Installation complete. You can reboot now."
echo "Remember to change default passwords immediately."
