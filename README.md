# custom-cachyos-iso

Кастомный установочный ISO для разворачивания системы "почти 1 в 1":
- ставит базу на новый диск (GPT + EFI + Btrfs subvolumes),
- применяет твой `system-bootstrap` (repo-пакеты, AUR, сервисы, `home`),
- создает пользователя и настраивает загрузчик.

## Что в репозитории

- `build.sh` - сборка ISO через `mkarchiso`.
- `overlay/airootfs/usr/local/bin/deploy-1to1.sh` - установщик внутри live-среды.
- `scripts/install-deps.sh` - установка зависимостей сборки.
- `system-bootstrap/` - submodule с payload твоей системы.

## 1) Как загрузить этот проект на GitHub

Если репозиторий уже создан на GitHub:

```bash
cd /home/goringich/custom-cachyos-iso
git add .gitignore .gitmodules README.md build.sh overlay scripts system-bootstrap
git commit -m "Prepare project for GitHub: docs, ignore rules, helper scripts"
git push origin master
```

Если хочешь новый репозиторий:

```bash
cd /home/goringich/custom-cachyos-iso
git init
git add .gitignore .gitmodules README.md build.sh overlay scripts system-bootstrap
git commit -m "Initial custom-cachyos-iso"
git branch -M main
git remote add origin git@github.com:<your_user>/<your_repo>.git
git push -u origin main
```

## 2) Как скачать и собрать ISO на другой машине

Требования: Arch/CachyOS, `sudo`, интернет.

```bash
git clone git@github.com:<your_user>/<your_repo>.git
cd <your_repo>
git submodule update --init --recursive
sudo ./scripts/install-deps.sh
```

По умолчанию `build.sh` использует payload из `./system-bootstrap`.
Если нужен другой источник, можно переопределить `PAYLOAD_SRC`:

```bash
export PAYLOAD_SRC=/absolute/path/to/system-bootstrap
sudo ./build.sh
```

Готовый образ будет в `out/`.

## 3) Как записать ISO на флешку

```bash
lsblk
sudo dd if=out/archlinux-YYYY.MM.DD-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Где `/dev/sdX` - устройство флешки целиком (не раздел, не `sdX1`).

## 4) Как запустить установку из Live ISO

После загрузки с флешки в live-системе:

```bash
deploy-1to1.sh \
  --disk /dev/nvme0n1 \
  --hostname cachy-main \
  --user goringich \
  --timezone Europe/Moscow \
  --locale ru_RU
```

По умолчанию временные пароли:
- `root/changeme`
- `<user>/changeme`

После первой загрузки обязательно поменяй:

```bash
passwd
passwd goringich
```

## Важно

- Выбранный диск очищается полностью.
- Поддерживается UEFI x86_64.
- AUR этап может идти долго; включена многопоточность.
- `out/` и `work/` не коммитятся (см. `.gitignore`).
