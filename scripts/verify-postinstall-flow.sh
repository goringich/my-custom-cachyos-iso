#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_SRC="${PAYLOAD_SRC:-$ROOT_DIR/system-bootstrap}"
POSTINSTALL_SCRIPT="$ROOT_DIR/overlay/airootfs/usr/local/lib/custom-cachyos-iso/post-install-1to1.sh"
TMP_DIR="$(mktemp -d)"
TARGET_ROOT="$TMP_DIR/rootfs"
COMMAND_LOG="$TMP_DIR/postinstall-commands.log"
FIRSTBOOT_COMMAND_LOG="$TMP_DIR/firstboot-commands.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

[[ -x "$POSTINSTALL_SCRIPT" ]] || fail "Missing post-install script: $POSTINSTALL_SCRIPT"
[[ -d "$PAYLOAD_SRC" ]] || fail "Missing payload source: $PAYLOAD_SRC"

mkdir -p \
  "$TARGET_ROOT/root/system-bootstrap" \
  "$TARGET_ROOT/etc/sudoers.d" \
  "$TARGET_ROOT/etc/systemd/system" \
  "$TARGET_ROOT/usr/local/bin" \
  "$TARGET_ROOT/home" \
  "$TARGET_ROOT/boot/grub" \
  "$TARGET_ROOT/efi"
printf '# ru_RU.UTF-8 UTF-8\n' > "$TARGET_ROOT/etc/locale.gen"

rsync -a --no-owner --no-group --delete --exclude '.git' "$PAYLOAD_SRC/" "$TARGET_ROOT/root/system-bootstrap/"

TARGET_ROOT="$TARGET_ROOT" \
POSTINSTALL_TEST_MODE=1 \
POSTINSTALL_COMMAND_LOG="$COMMAND_LOG" \
bash "$POSTINSTALL_SCRIPT" portable-lab tester Europe/Moscow ru_RU ru changeme changeme

grep -q '^portable-lab$' "$TARGET_ROOT/etc/hostname" || fail "hostname was not written"
grep -q '^LANG=ru_RU.UTF-8$' "$TARGET_ROOT/etc/locale.conf" || fail "locale.conf was not written"
grep -q '^KEYMAP=ru$' "$TARGET_ROOT/etc/vconsole.conf" || fail "vconsole.conf was not written"
grep -q '^tester:' "$TARGET_ROOT/etc/passwd.mock" || fail "tester user was not created in test mode"
[[ -f "$TARGET_ROOT/home/tester/.zshrc" ]] || fail "shared restore layer did not restore home payload"
[[ -f "$TARGET_ROOT/home/tester/.config/hypr/monitors.conf" ]] || fail "shared restore layer did not restore desktop payload"
[[ -f "$TARGET_ROOT/root/system-bootstrap/manifests/enabled-user-units.txt" ]] || fail "enabled-user-units manifest missing from bundled payload"
grep -q '^codex-obsidian-sync.timer$' "$TARGET_ROOT/root/system-bootstrap/manifests/enabled-user-units.txt" || fail "enabled-user-units manifest missing codex-obsidian-sync.timer"
[[ -L "$TARGET_ROOT/home/tester/.config/systemd/user/timers.target.wants/codex-obsidian-sync.timer" ]] || fail "user timer intent for codex-obsidian-sync.timer was not restored"
[[ -L "$TARGET_ROOT/home/tester/.config/systemd/user/default.target.wants/openclaw-gateway.service" ]] || fail "user default-target intent for openclaw-gateway.service was not restored"
[[ -x "$TARGET_ROOT/home/tester/.config/hypr/scripts/CaptureBrowserText.sh" ]] || fail "portable browser-text Hypr wrapper missing after restore"
[[ -x "$TARGET_ROOT/home/tester/.local/bin/browser-text-relay-tunnel-ensure" ]] || fail "portable browser-text relay helper missing after restore"
[[ -x "$TARGET_ROOT/home/tester/__home_organized/scripts/active-window-text-log.py" ]] || fail "portable browser-text capture script missing after restore"
[[ -x "$TARGET_ROOT/usr/local/bin/system-bootstrap-restore-audit.sh" ]] || fail "restore audit wrapper missing"
[[ -x "$TARGET_ROOT/usr/local/bin/system-bootstrap-firstboot.sh" ]] || fail "firstboot helper missing"
grep -q 'ExecStart=/usr/local/bin/system-bootstrap-firstboot.sh tester' "$TARGET_ROOT/etc/systemd/system/system-bootstrap-firstboot.service" || fail "firstboot service missing correct ExecStart"
[[ -L "$TARGET_ROOT/etc/systemd/system/multi-user.target.wants/system-bootstrap-firstboot.service" ]] || fail "firstboot service was not enabled"
[[ -f "$TARGET_ROOT/boot/grub/grub.cfg" ]] || fail "grub config was not generated in test mode"
grep -q '^NetworkManager$' "$TARGET_ROOT/var/lib/custom-cachyos-iso/enabled-units.log" || fail "NetworkManager enable step missing"
grep -q '^system-bootstrap-firstboot.service$' "$TARGET_ROOT/var/lib/custom-cachyos-iso/enabled-units.log" || fail "firstboot unit enable step missing"
grep -q '^clone-repos tester$' "$COMMAND_LOG" || fail "repo hydration path did not run"

SYSTEM_BOOTSTRAP_FIRSTBOOT_TEST_MODE=1 \
SYSTEM_BOOTSTRAP_FIRSTBOOT_TARGET_ROOT="$TARGET_ROOT" \
SYSTEM_BOOTSTRAP_FIRSTBOOT_COMMAND_LOG="$FIRSTBOOT_COMMAND_LOG" \
"$TARGET_ROOT/usr/local/bin/system-bootstrap-firstboot.sh" tester

[[ -f "$TARGET_ROOT/home/tester/.local/state/system-bootstrap/restore-report.txt" ]] || fail "firstboot restore audit report missing"
grep -q '^Restore verification report$' "$TARGET_ROOT/home/tester/.local/state/system-bootstrap/restore-report.txt" || fail "firstboot restore audit report malformed"
grep -q '^clone-repos tester$' "$FIRSTBOOT_COMMAND_LOG" || fail "firstboot repo hydration path did not run"
grep -q '^systemctl disable system-bootstrap-firstboot.service$' "$FIRSTBOOT_COMMAND_LOG" || fail "firstboot self-disable was not attempted"
[[ ! -e "$TARGET_ROOT/etc/systemd/system/system-bootstrap-firstboot.service" ]] || fail "firstboot service file was not cleaned up"
[[ ! -e "$TARGET_ROOT/etc/systemd/system/multi-user.target.wants/system-bootstrap-firstboot.service" ]] || fail "firstboot service symlink was not cleaned up"

echo "verify-postinstall-flow ok"
