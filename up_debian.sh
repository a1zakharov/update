#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 022
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

readonly APT_LOCK_TIMEOUT=300
readonly -a APT_OPTIONS=(-o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}")

section() {
    printf '\n%s\n' "============================================================"
    printf '%s\n' "$1"
    printf '%s\n' "============================================================"
}

confirm_no() {
    local answer
    read -r -p "$1 [y/N] " answer
    case "${answer,,}" in
        y|yes|д|да) return 0 ;;
        *)           return 1 ;;
    esac
}

confirm_yes() {
    local answer
    read -r -p "$1 [Y/n] " answer
    case "${answer,,}" in
        ''|y|yes|д|да) return 0 ;;
        *)             return 1 ;;
    esac
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Ошибка: не найдена обязательная команда: %s\n' "$1" >&2
        exit 1
    fi
}

on_error() {
    local exit_code=$?
    printf '\nОшибка на строке %s, код завершения %s. Обновление остановлено.\n' \
        "${BASH_LINENO[0]}" "$exit_code" >&2
    exit "$exit_code"
}

trap on_error ERR

section 'Debian/Ubuntu System Update'

if (( EUID == 0 )); then
    printf 'Не запускайте этот скрипт через sudo.\n' >&2
    printf 'Запустите от обычного пользователя: ./up_debian.sh\n' >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    printf 'Ошибка: не найден /etc/os-release.\n' >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
distribution="${ID:-unknown} ${ID_LIKE:-}"

case "$distribution" in
    *debian*|*ubuntu*) ;;
    *)
        printf 'Ошибка: скрипт предназначен только для Debian/Ubuntu-совместимых систем.\n' >&2
        printf 'Обнаружено: ID=%s, ID_LIKE=%s\n' "${ID:-unknown}" "${ID_LIKE:-unknown}" >&2
        exit 1
        ;;
esac

for command_name in sudo apt-get apt-mark dpkg grep df uname awk sed; do
    require_command "$command_name"
done

printf 'Система: %s\n' "${PRETTY_NAME:-$ID}"
printf 'Скрипт обновит APT-репозитории, включая настроенные сторонние репозитории.\n'
printf 'DEB без подключённого репозитория, AppImage и программы из pip/npm он не обновляет.\n'

section 'Предварительная проверка'

printf 'Свободное место:\n'
df -h / /var 2>/dev/null | awk '!seen[$NF]++'

held_packages=$(apt-mark showhold || true)
if [[ -n "$held_packages" ]]; then
    printf '\nПакеты на удержании (hold) — они не будут обновлены:\n%s\n' "$held_packages"
else
    printf '\nУдерживаемых пакетов нет.\n'
fi

printf '\nПроверка доступа sudo...\n'
sudo -v

printf 'Проверка состояния dpkg/APT...\n'
dpkg_audit=$(sudo dpkg --audit)
if [[ -n "$dpkg_audit" ]]; then
    printf 'Dpkg сообщает о незавершённых или повреждённых пакетах:\n%s\n' "$dpkg_audit" >&2
    printf 'Сначала исправьте состояние dpkg вручную, затем повторите обновление.\n' >&2
    exit 1
fi
sudo apt-get "${APT_OPTIONS[@]}" check

if command -v timeshift >/dev/null 2>&1; then
    printf '\n'
    if confirm_yes 'Timeshift найден. Создать снимок перед обновлением?'; then
        if ! sudo timeshift --create \
            --comments 'Перед обновлением Debian/Ubuntu' \
            --scripted; then
            printf 'Не удалось создать снимок Timeshift.\n' >&2
            if ! confirm_no 'Продолжить обновление без нового снимка?'; then
                printf 'Обновление отменено.\n'
                exit 1
            fi
        fi
    else
        printf 'Создание снимка пропущено пользователем.\n'
    fi
else
    printf '\nTimeshift не установлен; снимок пропущен.\n'
fi

section 'Обновление индексов APT'

sudo apt-get "${APT_OPTIONS[@]}" update
sudo apt-get "${APT_OPTIONS[@]}" check

section 'Предварительный план полного обновления'

upgrade_plan=$(sudo apt-get "${APT_OPTIONS[@]}" --simulate full-upgrade)
printf '%s\n' "$upgrade_plan"

upgrade_count=$(grep -c '^Inst ' <<<"$upgrade_plan" || true)
upgrade_removal_count=$(grep -c '^Remv ' <<<"$upgrade_plan" || true)

printf '\nПлан: установить/обновить — %s; удалить — %s.\n' \
    "$upgrade_count" "$upgrade_removal_count"

if (( upgrade_count > 0 || upgrade_removal_count > 0 )); then
    if (( upgrade_removal_count > 0 )); then
        printf 'ВНИМАНИЕ: full-upgrade планирует удаление пакетов. Проверьте список выше.\n' >&2
    fi

    if confirm_no 'Выполнить показанный full-upgrade?'; then
        # Без --assume-yes: APT ещё раз покажет окончательный план и запросит подтверждение.
        sudo apt-get "${APT_OPTIONS[@]}" full-upgrade
        sudo apt-get "${APT_OPTIONS[@]}" check
    else
        printf 'APT full-upgrade пропущен пользователем.\n'
    fi
else
    printf 'APT-пакеты уже актуальны.\n'
fi

section 'Проверка автоматически удаляемых пакетов'

autoremove_plan=$(sudo apt-get "${APT_OPTIONS[@]}" --simulate autoremove)
autoremove_count=$(grep -c '^Remv ' <<<"$autoremove_plan" || true)

if (( autoremove_count > 0 )); then
    printf '%s\n' "$autoremove_plan"
    printf '\nК удалению предложено пакетов: %s\n' "$autoremove_count"

    if confirm_no 'Удалить перечисленные пакеты через apt-get autoremove?'; then
        sudo apt-get "${APT_OPTIONS[@]}" autoremove
    else
        printf 'Autoremove пропущен пользователем.\n'
    fi
else
    printf 'Неиспользуемых зависимостей для удаления нет.\n'
fi

printf '\nОчистка устаревших файлов из APT-кэша...\n'
sudo apt-get "${APT_OPTIONS[@]}" autoclean

section 'Дополнительные менеджеры пакетов'

if command -v flatpak >/dev/null 2>&1; then
    if confirm_yes 'Обновить Flatpak-приложения?'; then
        flatpak update
    else
        printf 'Обновление Flatpak пропущено.\n'
    fi
else
    printf 'Flatpak не установлен.\n'
fi

if command -v snap >/dev/null 2>&1; then
    if confirm_yes 'Запустить внеплановое обновление Snap-пакетов?'; then
        sudo snap refresh
    else
        printf 'Snap refresh пропущен; snapd продолжит автоматические обновления.\n'
    fi
else
    printf 'Snap не установлен.\n'
fi

section 'Проверка необходимости перезагрузки'

if [[ -f /run/reboot-required ]]; then
    printf 'Требуется перезагрузка системы.\n'
    if [[ -s /run/reboot-required.pkgs ]]; then
        printf 'Причина — обновление пакетов:\n'
        sed 's/^/  /' /run/reboot-required.pkgs
    fi
else
    printf 'Система не сообщает о необходимости перезагрузки.\n'
fi

printf '\nОбновление завершено.\n'
