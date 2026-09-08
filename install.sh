#!/bin/sh

# Compact bootstrap installer for WG Watchdog.

VERSION="1.3.0"
BASE_URL="https://raw.githubusercontent.com/org1org/wg-watchdog/main"
WATCHDOG_URL="$BASE_URL/wg-watchdog.sh"
MANAGER_URL="$BASE_URL/wg-watchdog-manager.sh"
WATCHDOG_PATH="/opt/bin/wg-watchdog.sh"
MANAGER_PATH="/opt/bin/wg-watchdog-manager"
SHORT_COMMAND="/opt/bin/wgwm"
TMP_DIR="/tmp"
PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

TMP_FILES=""

cleanup() {
    for file in $TMP_FILES; do
        rm -f "$file"
    done
}
trap cleanup EXIT HUP INT TERM

say() { printf '%s\n' "$*"; }
die() { say "Ошибка: $*" >&2; exit 1; }

make_temp() {
    tmp_file="$TMP_DIR/wg-watchdog-install.$$.$1"
    TMP_FILES="$TMP_FILES $tmp_file"
    : > "$tmp_file" || die "не удалось создать временный файл $tmp_file"
    REPLY=$tmp_file
}

download_file() {
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2" && return 0
    fi
    return 1
}

install_if_changed() {
    source_file=$1
    destination=$2
    if [ -f "$destination" ] && cmp -s "$source_file" "$destination"; then
        rm -f "$source_file"
        return 0
    fi
    chmod 755 "$source_file" || die "не удалось установить права на $destination"
    mv "$source_file" "$destination" || die "не удалось установить $destination"
}

ensure_short_command() {
    if [ -L "$SHORT_COMMAND" ] && [ "$(readlink "$SHORT_COMMAND" 2>/dev/null)" = "$MANAGER_PATH" ]; then
        return 0
    fi
    if [ -e "$SHORT_COMMAND" ] || [ -L "$SHORT_COMMAND" ]; then
        say "Предупреждение: $SHORT_COMMAND уже занят; команда wgwm не создавалась."
        return 0
    fi
    existing_command=$(command -v wgwm 2>/dev/null || true)
    if [ -n "$existing_command" ]; then
        say "Предупреждение: команда wgwm уже занята ($existing_command); она не изменена."
        return 0
    fi
    ln -s "$MANAGER_PATH" "$SHORT_COMMAND" || die "не удалось создать команду wgwm"
}

[ "$(id -u 2>/dev/null)" = "0" ] || die "запустите установщик от пользователя root"
[ -d /opt ] || die "каталог /opt отсутствует — сначала установите Entware"
command -v opkg >/dev/null 2>&1 || die "команда opkg не найдена — Entware не запущен"
[ -r /dev/tty ] && [ -w /dev/tty ] || die "установщик нужно запускать из интерактивного терминала"
mkdir -p /opt/bin "$TMP_DIR" || die "не удалось подготовить каталог /opt/bin"

make_temp watchdog
tmp_watchdog=$REPLY
make_temp manager
tmp_manager=$REPLY

say "Загружаю WG Watchdog $VERSION..."
download_file "$WATCHDOG_URL" "$tmp_watchdog" || die "не удалось загрузить watchdog"
download_file "$MANAGER_URL" "$tmp_manager" || die "не удалось загрузить менеджер"
sh -n "$tmp_watchdog" || die "ошибка синтаксиса в загруженном watchdog"
sh -n "$tmp_manager" || die "ошибка синтаксиса в загруженном менеджере"

install_if_changed "$tmp_watchdog" "$WATCHDOG_PATH"
install_if_changed "$tmp_manager" "$MANAGER_PATH"
ensure_short_command

# Вызов по ссылке уже означает согласие начать настройку.
exec "$MANAGER_PATH" --from-installer
die "не удалось запустить менеджер"
