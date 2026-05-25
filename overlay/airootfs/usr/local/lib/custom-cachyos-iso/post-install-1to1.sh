#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="$1"
USERNAME="$2"
TIMEZONE="$3"
LOCALE="$4"
KEYMAP="$5"
ROOT_PASSWORD="$6"
USER_PASSWORD="$7"

TARGET_ROOT="${TARGET_ROOT:-}"
TEST_MODE="${POSTINSTALL_TEST_MODE:-0}"
COMMAND_LOG="${POSTINSTALL_COMMAND_LOG:-}"

log() { printf '[post] %s\n' "$*"; }

root_path() {
  local path="$1"
  if [[ -n "$TARGET_ROOT" ]]; then
    printf '%s%s\n' "${TARGET_ROOT%/}" "$path"
  else
    printf '%s\n' "$path"
  fi
}

payload_path() {
  local rel="${1#/}"
  printf '%s/%s\n' "$(root_path /root/system-bootstrap)" "$rel"
}

record_cmd() {
  [[ -n "$COMMAND_LOG" ]] || return 0
  printf '%s\n' "$*" >> "$COMMAND_LOG"
}

have_user() {
  local user="$1"
  if [[ "$TEST_MODE" -eq 1 ]]; then
    grep -q "^${user}:" "$(root_path /etc/passwd.mock)" 2>/dev/null
  else
    id -u "$user" >/dev/null 2>&1
  fi
}

create_user() {
  local user="$1"
  if [[ "$TEST_MODE" -eq 1 ]]; then
    mkdir -p "$(dirname "$(root_path /etc/passwd.mock)")" "$(root_path "/home/$user")"
    printf '%s:x:1000:1000::/home/%s:/bin/bash\n' "$user" "$user" >> "$(root_path /etc/passwd.mock)"
    record_cmd "useradd $user"
  else
    useradd -m -G wheel -s /bin/bash "$user"
  fi
}

set_password() {
  local user="$1"
  local password="$2"
  if [[ "$TEST_MODE" -eq 1 ]]; then
    mkdir -p "$(dirname "$(root_path /etc/shadow.mock)")"
    printf '%s:%s\n' "$user" "$password" >> "$(root_path /etc/shadow.mock)"
    record_cmd "chpasswd $user"
  else
    echo "${user}:${password}" | chpasswd
  fi
}

run_systemctl() {
  local action="$1"
  shift

  if [[ "$TEST_MODE" -eq 1 ]]; then
    local wants_dir unit
    wants_dir="$(root_path /etc/systemd/system/multi-user.target.wants)"
    mkdir -p "$wants_dir" "$(root_path /var/lib/custom-cachyos-iso)"
    case "$action" in
      enable)
        for unit in "$@"; do
          printf '%s\n' "$unit" >> "$(root_path /var/lib/custom-cachyos-iso/enabled-units.log)"
          if [[ -f "$(root_path "/etc/systemd/system/$unit")" ]]; then
            ln -sfn "../$unit" "$wants_dir/$unit"
          fi
        done
        ;;
      disable)
        for unit in "$@"; do
          rm -f "$wants_dir/$unit"
          printf '%s\n' "$unit" >> "$(root_path /var/lib/custom-cachyos-iso/disabled-units.log)"
        done
        ;;
      *)
        record_cmd "systemctl $action $*"
        ;;
    esac
    return 0
  fi

  systemctl "$action" "$@"
}

run_hwclock() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "hwclock --systohc"
    return 0
  fi
  hwclock --systohc
}

run_locale_gen() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "locale-gen"
    return 0
  fi
  locale-gen
}

run_pacman() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "pacman $*"
    return 0
  fi
  pacman "$@"
}

run_grub_install() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    mkdir -p "$(root_path /boot/grub)"
    record_cmd "grub-install $*"
    : > "$(root_path /boot/grub/.grub-install-stamp)"
    return 0
  fi
  grub-install "$@"
}

run_grub_mkconfig() {
  local output="$1"
  if [[ "$TEST_MODE" -eq 1 ]]; then
    mkdir -p "$(dirname "$(root_path "$output")")"
    printf '# mock grub config\n' > "$(root_path "$output")"
    record_cmd "grub-mkconfig -o $output"
    return 0
  fi
  grub-mkconfig -o "$output"
}

run_clone_repos() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "clone-repos $USERNAME"
    return 0
  fi

  runuser -u "$USERNAME" -- env HOME="/home/${USERNAME}" \
    bash "$(payload_path scripts/clone-repos.sh)" --mode clone-missing
}

run_codex_install() {
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "codex-orchestrator install $USERNAME"
    return 0
  fi

  runuser -u "$USERNAME" -- env HOME="/home/${USERNAME}" CODEX_ORCHESTRATOR_ENABLE_TIMER=0 \
    bash "$(root_path "/home/${USERNAME}/codex-orchestrator/install.sh")"
}

mkdir -p "$(dirname "$(root_path /etc/localtime)")"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "$(root_path /etc/localtime)"
run_hwclock

locale_gen_file="$(root_path /etc/locale.gen)"
mkdir -p "$(dirname "$locale_gen_file")"
touch "$locale_gen_file"
if ! grep -q "^${LOCALE}\.UTF-8 UTF-8" "$locale_gen_file"; then
  echo "${LOCALE}.UTF-8 UTF-8" >> "$locale_gen_file"
else
  sed -i "s/^#\(${LOCALE}\.UTF-8 UTF-8\)/\1/" "$locale_gen_file"
fi
run_locale_gen

printf 'LANG=%s.UTF-8\n' "$LOCALE" > "$(root_path /etc/locale.conf)"
printf 'KEYMAP=%s\n' "$KEYMAP" > "$(root_path /etc/vconsole.conf)"
printf '%s\n' "$HOSTNAME" > "$(root_path /etc/hostname)"

cat > "$(root_path /etc/hosts)" <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

if ! have_user "$USERNAME"; then
  create_user "$USERNAME"
fi

set_password root "$ROOT_PASSWORD"
set_password "$USERNAME" "$USER_PASSWORD"

mkdir -p "$(root_path /etc/sudoers.d)"
echo '%wheel ALL=(ALL:ALL) ALL' > "$(root_path /etc/sudoers.d/10-wheel)"
chmod 440 "$(root_path /etc/sudoers.d/10-wheel)"

run_systemctl enable NetworkManager

if [[ -f "$(payload_path pacman-host/pacman.conf)" ]]; then
  log "Applying bundled pacman repo config"
  mkdir -p "$(dirname "$(root_path /etc/pacman.conf)")"
  cp "$(payload_path pacman-host/pacman.conf)" "$(root_path /etc/pacman.conf)"
fi
if [[ -d "$(payload_path pacman-host/pacman.d)" ]]; then
  mkdir -p "$(root_path /etc/pacman.d)"
  rsync -a "$(payload_path pacman-host/pacman.d/)" "$(root_path /etc/pacman.d/)"
fi

if [[ -s "$(payload_path manifests/pacman-explicit-non-system.txt)" ]]; then
  log "Installing repo package manifest"
  run_pacman -Syu --noconfirm
  mapfile -t wanted < "$(payload_path manifests/pacman-explicit-non-system.txt)"
  install_list=()
  for pkg in "${wanted[@]}"; do
    [[ -n "$pkg" ]] || continue
    if run_pacman -Si "$pkg" >/dev/null 2>&1; then
      install_list+=("$pkg")
    else
      log "Skipping unavailable repo package: $pkg"
    fi
  done
  if [[ "${#install_list[@]}" -gt 0 ]]; then
    run_pacman -S --needed --noconfirm "${install_list[@]}"
  fi
fi

if [[ -x "$(payload_path scripts/install-all.sh)" ]]; then
  log "Applying shared system-bootstrap restore layer"
  install_args=(--skip-packages --skip-aur --no-backup)
  if [[ "$TEST_MODE" -eq 1 ]]; then
    install_args+=(--skip-services)
  fi
  TARGET_ROOT="${TARGET_ROOT:-/}" \
    TARGET_HOME="$(root_path "/home/${USERNAME}")" \
    SYSTEM_BOOTSTRAP_UNITS_MANIFEST="$(payload_path manifests/enabled-system-units.txt)" \
    bash "$(payload_path scripts/install-all.sh)" "${install_args[@]}"
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}"
  else
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"
  fi
fi

if [[ -x "$(payload_path scripts/clone-repos.sh)" && -f "$(payload_path configs/repos.txt)" ]]; then
  log "Hydrating workspace repositories"
  install -d "$(root_path "/home/${USERNAME}/Desktop")"
  run_clone_repos || log "Repo hydration skipped or partially failed"
fi

if [[ -x "$(root_path "/home/${USERNAME}/codex-orchestrator/install.sh")" ]]; then
  log "Installing codex-orchestrator into user environment"
  run_codex_install || log "codex-orchestrator install skipped or partially failed"
fi

mkdir -p "$(root_path /usr/local/bin)"
cat > "$(root_path /usr/local/bin/system-bootstrap-restore-audit.sh)" <<'AUDIT'
#!/usr/bin/env bash
set -euo pipefail
exec /root/system-bootstrap/scripts/restore-audit.sh "$@"
AUDIT
chmod +x "$(root_path /usr/local/bin/system-bootstrap-restore-audit.sh)"

cat > "$(root_path /usr/local/bin/system-bootstrap-firstboot.sh)" <<'FIRSTBOOT'
#!/usr/bin/env bash
set -euo pipefail

USERNAME="$1"
if [[ -x /root/system-bootstrap/scripts/clone-repos.sh && -f /root/system-bootstrap/configs/repos.txt ]]; then
  runuser -u "$USERNAME" -- env HOME="/home/${USERNAME}" \
    bash /root/system-bootstrap/scripts/clone-repos.sh --mode clone-missing || true
fi
if [[ -x /root/system-bootstrap/scripts/setup-hyprbars.sh ]]; then
  runuser -u "$USERNAME" -- env HOME="/home/${USERNAME}" \
    bash /root/system-bootstrap/scripts/setup-hyprbars.sh || true
fi
if [[ -x "/home/${USERNAME}/codex-orchestrator/install.sh" ]]; then
  runuser -u "$USERNAME" -- env HOME="/home/${USERNAME}" CODEX_ORCHESTRATOR_ENABLE_TIMER=0 \
    bash "/home/${USERNAME}/codex-orchestrator/install.sh" || true
fi
if [[ -x /usr/local/bin/system-bootstrap-restore-audit.sh ]]; then
  install -d -o "$USERNAME" -g "$USERNAME" "/home/${USERNAME}/.local/state/system-bootstrap"
  report_file="/home/${USERNAME}/.local/state/system-bootstrap/restore-report.txt"
  /usr/local/bin/system-bootstrap-restore-audit.sh "$USERNAME" "$report_file" "/home/${USERNAME}" || true
  chown "${USERNAME}:${USERNAME}" "$report_file" || true
fi
systemctl disable system-bootstrap-firstboot.service || true
rm -f /etc/systemd/system/system-bootstrap-firstboot.service
FIRSTBOOT
chmod +x "$(root_path /usr/local/bin/system-bootstrap-firstboot.sh)"

mkdir -p "$(root_path /etc/systemd/system)"
cat > "$(root_path /etc/systemd/system/system-bootstrap-firstboot.service)" <<SERVICE
[Unit]
Description=Retry workspace repo hydration after first boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-bootstrap-firstboot.sh ${USERNAME}

[Install]
WantedBy=multi-user.target
SERVICE
run_systemctl enable system-bootstrap-firstboot.service

log "Installing GRUB"
run_grub_install --target=x86_64-efi --efi-directory=/efi --bootloader-id=CachyCustom
run_grub_mkconfig /boot/grub/grub.cfg

if [[ -s "$(payload_path manifests/aur-explicit.txt)" ]]; then
  if [[ "$TEST_MODE" -eq 1 ]]; then
    record_cmd "aur-install $USERNAME"
  else
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
fi

log "Post-install completed"
