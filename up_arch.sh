#!/usr/bin/env bash
# Arch Linux: linux + mkinitcpio + GRUB, отдельный /boot.
# Запуск: Ctrl+Alt+F3 -> вход своим пользователем -> bash /путь/up_arch.sh
# Не запускать через sudo, sh или zsh. Пароли в журнал не записываются.
# Не защищает от отключения питания, аппаратного сбоя или принудительного SIGKILL.
set -Eeuo pipefail

BACKUP_MOUNT=/mnt/data
BACKUP_UUID=3a847648-b8ec-4b63-87b0-25ce93925c6e
BOOT_UUID=0FC7-8887
MIN_ROOT_MIB=2048
MIN_BOOT_MIB=300
# Состояние EXIT-обработчика должно сохраниться после возврата из main.
work_dir='' log_file='' logger_pid='' phase='начало' update_started=0

die() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }
step() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }

require_console() {
    local terminal
    terminal=$(tty) || die 'Нужна текстовая консоль: Ctrl+Alt+F3 и отдельный вход.'
    [[ $terminal =~ ^/dev/tty[0-9]+$ ]] ||
        die 'Запуск разрешён только из TTY (Ctrl+Alt+F3). Kitty, Konsole, SSH и tmux не подходят.'
    [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]] ||
        die 'Обнаружено графическое окружение. Войди отдельно через Ctrl+Alt+F3.'
    if grep -qE '/user@[0-9]+\.service(/|$)' /proc/self/cgroup; then
        die 'Процесс принадлежит пользовательскому менеджеру systemd. Нужен отдельный вход в TTY.'
    fi
}

check_mount() {
    local target=$1 expected=$2 actual options probe
    actual=$(findmnt -rn -M "$target" -o UUID) || die "$target не смонтирован."
    [[ $actual == "$expected" ]] || die "В $target подключён другой раздел (UUID: $actual)."
    options=$(findmnt -rn -M "$target" -o OPTIONS)
    [[ ,$options, == *,rw,* ]] || die "$target доступен только для чтения."
    probe=$(sudo mktemp "$target/.up_arch-write-test.XXXXXX") || die "Не удалось записать в $target."
    sudo rm -- "$probe"
}

check_space() {
    local target=$1 minimum=$2 available
    available=$(df -Pm -- "$target" | awk 'NR == 2 {print $4}')
    [[ $available =~ ^[0-9]+$ ]] || die "Не удалось проверить место на $target."
    (( available >= minimum )) || die "На $target свободно ${available} МиБ; требуется минимум ${minimum} МиБ."
}

check_pacman_lock() {
    [[ ! -e /var/lib/pacman/db.lck ]] ||
        die 'Есть /var/lib/pacman/db.lck. Проверь процессы pacman; скрипт не удаляет блокировку автоматически.'
}

get_kernel() {
    local files
    local -a images=()
    files=$(pacman -Qql linux) || die 'Пакет linux не установлен.'
    mapfile -t images < <(printf '%s\n' "$files" | grep -E '^/usr/lib/modules/[^/]+/vmlinuz$')
    (( ${#images[@]} == 1 )) || die 'Не удалось однозначно определить файл ядра пакета linux.'
    kernel_image=${images[0]}
    kernel_version=${kernel_image#/usr/lib/modules/}
    kernel_version=${kernel_version%/vmlinuz}
    [[ -s $kernel_image ]] || die "Нет файла $kernel_image."
}

verify_boot() {
    get_kernel
    [[ -s /boot/vmlinuz-linux && -s /boot/initramfs-linux.img ]] ||
        die 'В /boot отсутствует ядро или initramfs. Требуется восстановление; обновление остановлено.'
    cmp -s -- "$kernel_image" /boot/vmlinuz-linux || die 'Ядро в /boot не совпадает с установленным пакетом linux.'
    sudo lsinitcpio -l /boot/initramfs-linux.img > "$work_dir/initramfs.list"
    grep -Fq "usr/lib/modules/$kernel_version/" "$work_dir/initramfs.list" ||
        die "В initramfs не найдены модули установленного ядра $kernel_version."
    printf 'Ядро и initramfs согласованы: %s\n' "$kernel_version"
}

rebuild_boot() {
    local statuses module row found
    check_mount /boot "$BOOT_UUID"
    get_kernel
    if command -v dkms >/dev/null 2>&1; then
        sudo dkms autoinstall -k "$kernel_version"
        statuses=$(sudo dkms status -k "$kernel_version")
        printf '%s\n' "$statuses"
        for module in "${dkms_modules[@]}"; do
            found=0
            while IFS= read -r row; do
                if [[ $row == "$module/"* && $row == *", $kernel_version,"* && $row == *": installed" ]]; then
                    found=1
                fi
            done <<< "$statuses"
            (( found == 1 )) || die "DKMS-модуль $module не установлен для $kernel_version. Не перезагружайся."
        done
    elif (( ${#dkms_modules[@]} > 0 )); then
        die 'После обновления пропал dkms. Не перезагружайся.'
    fi
    # Явный повтор ловит ошибку сборки, даже если менеджер пакетов не вернул её.
    sudo mkinitcpio -P
    verify_boot
    # Генерируем и проверяем новый конфиг до замены действующего.
    sudo grub-mkconfig -o /boot/grub/grub.cfg.up_arch.new
    sudo grub-script-check /boot/grub/grub.cfg.up_arch.new
    sudo grep -Eq '^[[:space:]]*linux(efi)?[[:space:]]+[^[:space:]]*vmlinuz-linux([[:space:]]|$)' \
        /boot/grub/grub.cfg.up_arch.new || die 'GRUB не добавил установленное ядро.'
    sudo cp -- /boot/grub/grub.cfg /boot/grub/grub.cfg.up_arch.previous
    sudo mv -- /boot/grub/grub.cfg.up_arch.new /boot/grub/grub.cfg
    sudo sync -f /boot
}

finish() {
    local rc=$?
    trap - EXIT
    set +e
    [[ -z ${work_dir:-} ]] || rm -rf -- "$work_dir"
    if (( rc != 0 )); then
        printf '\nСкрипт остановлен, код %s. Этап: %s\n' "$rc" "${phase:-начало}"
        if [[ ${update_started:-0} == 1 ]]; then
            printf 'Обновление могло остаться незавершённым. НЕ ПЕРЕЗАГРУЖАЙСЯ до проверки ядра, initramfs и DKMS.\n'
        fi
    fi
    [[ -z ${log_file:-} ]] || printf 'Журнал: %s\n' "$log_file"
    # Закрыть pipe и дождаться записи последних строк tee.
    if [[ -n ${logger_pid:-} ]]; then
        exec 1>&3 2>&4
        if ! wait "$logger_pid"; then
            printf 'Не удалось полностью записать журнал.\n' >&2
            (( rc != 0 )) || rc=1
        fi
    fi
    exit "$rc"
}

main() {
    local cmd run_id log_dir backup_dir backup_need boot_size answer status_text row module
    local mirror_backup running_kernel orphan_list
    local -a dkms_modules=()
    local kernel_image='' kernel_version=''
    phase='проверки перед запуском'

    (( $# == 0 )) || die 'Параметры не поддерживаются. Запуск: bash up_arch.sh'
    (( EUID != 0 )) || die 'Запускай своим пользователем, без sudo: bash up_arch.sh'
    require_console
    [[ -f /etc/arch-release ]] || die 'Нужен установленный Arch Linux, не Live USB/chroot.'
    for cmd in sudo pacman yay timeshift findmnt mktemp flock tee df awk grep \
               tar cmp lsinitcpio mkinitcpio grub-mkconfig grub-script-check sync; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена команда: $cmd"
    done
    # Локальная блокировка всего сценария, независимая от блокировки pacman.
    log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/up_arch"
    mkdir -p -- "$log_dir"
    chmod 700 -- "$log_dir"
    exec 9> "$log_dir/run.lock"
    flock -n 9 || die 'Другой экземпляр up_arch уже работает.'
    run_id="$(date '+%Y-%m-%d_%H-%M-%S')-$$"
    log_file="$log_dir/$run_id.log"
    umask 077
    exec 3>&1 4>&2
    exec > >(tee -a -- "$log_file") 2>&1
    logger_pid=$!
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    work_dir=$(mktemp -d)
    step 'Проверки перед обновлением'
    sudo -v
    check_pacman_lock
    check_mount "$BACKUP_MOUNT" "$BACKUP_UUID"
    check_mount /boot "$BOOT_UUID"
    check_space / "$MIN_ROOT_MIB"
    check_space /boot "$MIN_BOOT_MIB"
    pacman -Q linux linux-headers mkinitcpio grub
    [[ -s /boot/grub/grub.cfg ]] || die 'Нет действующего /boot/grub/grub.cfg.'
    verify_boot
    if command -v dkms >/dev/null 2>&1; then
        status_text=$(sudo dkms status)
        printf '%s\n' "$status_text"
        while IFS= read -r row; do
            [[ -n $row && $row == */* ]] || continue
            module=${row%%/*}
            if [[ " ${dkms_modules[*]} " != *" $module "* ]]; then dkms_modules+=("$module"); fi
        done <<< "$status_text"
    fi
    printf '\nПроверь объявления https://archlinux.org/news/ перед обновлением.\n'
    read -r -p 'Продолжить полное обновление? [y/N] ' answer
    [[ $answer == [yY] || $answer == да ]] || { printf 'Обновление отменено.\n'; return 0; }

    phase='резервные копии'
    step 'Снимок Timeshift и отдельная копия /boot'
    boot_size=$(sudo du -sm /boot | awk '{print $1}')
    backup_need=$(( boot_size + 512 ))
    check_space "$BACKUP_MOUNT" "$backup_need"
    sudo timeshift --create --rsync --snapshot-device "$BACKUP_UUID" \
        --comments "Перед up_arch $run_id" --tags O --scripted
    check_space "$BACKUP_MOUNT" "$backup_need"
    backup_dir="$BACKUP_MOUNT/up_arch-backups/$run_id"
    sudo install -d -m 700 -- "$backup_dir"
    sudo tar -C /boot -cpf "$backup_dir/boot.tar" .
    sudo tar -tf "$backup_dir/boot.tar" >/dev/null
    sudo cp -- /etc/fstab /etc/pacman.conf /etc/pacman.d/mirrorlist "$backup_dir/"
    pacman -Q | sudo tee "$backup_dir/packages.txt" >/dev/null
    sudo sync -f "$BACKUP_MOUNT"
    printf 'Дополнительная копия загрузочных файлов: %s/boot.tar\n' "$backup_dir"

    phase='обновление зеркал'
    step 'Зеркала'
    if command -v reflector >/dev/null 2>&1; then
        if reflector --latest 20 --protocol https --sort rate --save "$work_dir/mirrorlist" \
           && grep -qE '^Server[[:space:]]*=' "$work_dir/mirrorlist"; then
            mirror_backup="/etc/pacman.d/mirrorlist.backup.$run_id"
            sudo cp --preserve=mode,ownership,timestamps /etc/pacman.d/mirrorlist "$mirror_backup"
            sudo install -o root -g root -m 644 "$work_dir/mirrorlist" /etc/pacman.d/mirrorlist
        else
            printf 'Reflector не подготовил список. Используется прежний mirrorlist.\n'
        fi
    else
        printf 'Reflector отсутствует; используется прежний mirrorlist.\n'
    fi

    phase='официальные пакеты'
    step 'Полное обновление официальных пакетов'
    check_mount /boot "$BOOT_UUID"
    check_pacman_lock
    update_started=1
    sudo pacman -Syu
    phase='проверка загрузки после официальных пакетов'
    rebuild_boot

    phase='AUR'
    step 'Обновление AUR (проверь предлагаемые изменения PKGBUILD)'
    check_pacman_lock
    yay -Sua
    # AUR может менять NVIDIA/DKMS. Финальная сборка должна быть после него.
    phase='финальная проверка загрузки'
    rebuild_boot
    sudo pacman -Dk
    update_started=0

    phase='дополнительное обслуживание'
    step 'Кэш пакетов и список неиспользуемых зависимостей'
    if command -v paccache >/dev/null 2>&1; then
        sudo paccache -rk3
    else
        printf 'Paccache отсутствует; кэш оставлен без изменений.\n'
    fi
    orphan_list=$(pacman -Qtdq || true)
    if [[ -n $orphan_list ]]; then
        printf 'Orphan-пакеты (только список, удаления нет):\n%s\n' "$orphan_list"
    else
        printf 'Orphan-пакетов нет.\n'
    fi
    if command -v flatpak >/dev/null 2>&1; then
        step 'Flatpak'
        flatpak update
    fi
    if command -v pacdiff >/dev/null 2>&1; then
        step 'Конфигурационные файлы .pacnew/.pacsave'
        sudo pacdiff --output
    fi
    running_kernel=$(uname -r)
    step 'Обновление завершено; загрузочные файлы и DKMS проверены'
    printf 'Работающее ядро: %s. Установленное ядро: %s.\n' "$running_kernel" "$kernel_version"
    printf 'Рекомендуется перезагрузка после сохранения работы. Автоматической перезагрузки нет.\n'
    printf 'Проверки не гарантируют загрузку при аппаратных сбоях или ошибках нового ядра.\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
