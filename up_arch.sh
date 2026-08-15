#!/bin/zsh

set -euo pipefail

print '==============================='
print ' Arch Linux Full Update Script '
print '==============================='

if (( EUID == 0 )); then
    print -u2 'Не запускайте этот скрипт через sudo.'
    print -u2 'Запустите от обычного пользователя: ./up.sh'
    exit 1
fi

for command_name in sudo pacman yay timeshift; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        print -u2 "Не найдена обязательная команда: $command_name"
        exit 1
    fi
done

print
print 'Проверка доступа sudo...'
sudo -v

print
print '[1/7] Создание снимка Timeshift...'
sudo timeshift --create --comments 'Перед обновлением системы' --scripted

print
print '[2/7] Обновление mirrorlist через reflector...'

if ! command -v reflector >/dev/null 2>&1; then
    print 'Reflector не установлен. Устанавливаю с полным обновлением репозиторных пакетов...'
    sudo pacman -Syu --needed reflector
fi

mirrorlist_backup="/etc/pacman.d/mirrorlist.backup.$(date +%Y%m%d-%H%M%S)"
sudo cp --preserve=mode,ownership,timestamps \
    /etc/pacman.d/mirrorlist "$mirrorlist_backup"
print "Резервная копия mirrorlist: $mirrorlist_backup"

sudo reflector \
    --latest 20 \
    --protocol https \
    --sort rate \
    --save /etc/pacman.d/mirrorlist

print
print '[3/7] Обновление официальных и AUR-пакетов...'
print 'Yay покажет доступные обновления и изменения PKGBUILD перед установкой.'
yay -Syu

print
print '[4/7] Очистка старого кэша пакетов...'

if command -v paccache >/dev/null 2>&1; then
    sudo paccache -r
else
    print 'Paccache не установлен; очистка кэша пропущена.'
fi

print
print '[5/7] Проверка неиспользуемых зависимостей...'

orphans_output=$(pacman -Qtdq 2>/dev/null || true)
orphans=()

if [[ -n "$orphans_output" ]]; then
    orphans=("${(@f)orphans_output}")
fi

if (( ${#orphans[@]} > 0 )); then
    print 'Найдены orphan-пакеты:'
    printf '  %s\n' "${orphans[@]}"
    print
    read -r 'remove_orphans?Удалить их вместе с конфигурацией и зависимостями? [y/N] '

    case "${remove_orphans:l}" in
        y|yes|д|да)
            sudo pacman -Rns -- "${orphans[@]}"
            ;;
        *)
            print 'Удаление orphan-пакетов пропущено.'
            ;;
    esac
else
    print 'Orphan-пакетов нет.'
fi

print
print '[6/7] Обновление Flatpak-приложений...'

if command -v flatpak >/dev/null 2>&1; then
    flatpak update
else
    print 'Flatpak не установлен; шаг пропущен.'
fi

print
print '[7/7] Проверка необходимости перезагрузки...'

running_kernel=$(uname -r)
if [[ ! -d "/usr/lib/modules/$running_kernel" ]] || [[ -f /run/reboot-required ]]; then
    print 'Рекомендуется перезагрузка: обновилось ядро или установлен соответствующий флаг.'
else
    print 'Явных признаков необходимости перезагрузки нет.'
fi

print
print 'Обновление завершено.'
