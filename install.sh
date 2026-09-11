#!/bin/sh

# Compact bootstrap installer for WG Watchdog Manager.

VERSION="1.0.1"
BASE_URL="${WG_WATCHDOG_BASE_URL:-https://raw.githubusercontent.com/org1org/wg-watchdog/main}"
RAW_REPOSITORY_URL="${WG_WATCHDOG_RAW_REPOSITORY_URL:-https://raw.githubusercontent.com/org1org/wg-watchdog}"
RELEASE_MANIFEST_URL="${WG_WATCHDOG_RELEASE_MANIFEST_URL:-$BASE_URL/RELEASE}"
OPT_ROOT="${WG_WATCHDOG_OPT_ROOT:-/opt}"
WATCHDOG_PATH="${WG_WATCHDOG_INSTALL_WATCHDOG:-$OPT_ROOT/bin/wg-watchdog.sh}"
MANAGER_PATH="${WG_WATCHDOG_INSTALL_MANAGER:-$OPT_ROOT/bin/wg-watchdog-manager}"
SHORT_COMMAND="${WG_WATCHDOG_INSTALL_SHORT_COMMAND:-$OPT_ROOT/bin/wgwm}"
TMP_DIR="${WG_WATCHDOG_TMP_DIR:-/tmp}"
TTY_DEVICE="${WG_WATCHDOG_TTY:-/dev/tty}"
INPUT_DEVICE="${WG_WATCHDOG_INPUT:-$TTY_DEVICE}"
OUTPUT_DEVICE="${WG_WATCHDOG_OUTPUT:-$TTY_DEVICE}"
OPKG_BIN="${WG_WATCHDOG_OPKG:-opkg}"
NDMC_BIN="${WG_WATCHDOG_NDMC:-ndmc}"
CRON_INIT="${WG_WATCHDOG_CRON_INIT:-$OPT_ROOT/etc/init.d/S10cron}"
PIDOF_BIN="${WG_WATCHDOG_PIDOF:-pidof}"
SHA256_BIN="${WG_WATCHDOG_SHA256:-sha256sum}"
PATH="${WG_WATCHDOG_INSTALL_PATH:-$OPT_ROOT/bin:$OPT_ROOT/sbin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

TMP_FILES=""
umask 077
FORCE_INSTALL=no

cleanup() {
    printf '%s' "$TMP_FILES" | while IFS= read -r file; do
        [ -n "$file" ] && rm -f "$file"
    done
    TMP_FILES=""
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

say() { printf '%s\n' "$*"; }
die() { say "Ошибка: $*" >&2; exit 1; }

confirm_yes() {
    printf '%s [Y/n]: ' "$1" > "$OUTPUT_DEVICE"
    IFS= read -r answer < "$INPUT_DEVICE" || die "не удалось прочитать ответ"
    case "$answer" in
        n|N|no|NO|No|н|Н|нет|Нет|НЕТ) return 1 ;;
        *) return 0 ;;
    esac
}

make_temp() {
    tmp_file=$(mktemp "$TMP_DIR/wg-watchdog.$1.XXXXXX") || die "не удалось создать временный файл"
    TMP_FILES="${TMP_FILES}${tmp_file}
"
    REPLY=$tmp_file
}

download_file() {
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -O "$2" "$1" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 20 "$1" -o "$2" && return 0
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

validate_script_version() {
    script_file=$1
    script_name=$2
    downloaded_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$script_file" | sed -n '1p')
    [ "$downloaded_version" = "$VERSION" ] || \
        die "$script_name имеет версию ${downloaded_version:-неизвестно}, ожидалась $VERSION; установка отменена"
}

fetch_release_manifest() {
    make_temp release
    release_file=$REPLY
    download_file "$RELEASE_MANIFEST_URL" "$release_file" || die "не удалось загрузить манифест выпуска"
    release_values=$(awk -F= '
        $1 == "VERSION" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { version = $2; versions++; next }
        $1 == "COMMIT" && length($2) == 40 && $2 !~ /[^0-9a-f]/ { commit = $2; commits++; next }
        $1 == "WATCHDOG_SHA256" && length($2) == 64 && $2 !~ /[^0-9a-f]/ { watchdog = $2; watchdogs++; next }
        $1 == "MANAGER_SHA256" && length($2) == 64 && $2 !~ /[^0-9a-f]/ { manager = $2; managers++; next }
        { bad = 1 }
        END {
            if (bad || versions != 1 || commits != 1 || watchdogs != 1 || managers != 1) exit 1
            print version "\t" commit "\t" watchdog "\t" manager
        }
    ' "$release_file") || die "некорректный манифест выпуска"
    old_ifs=$IFS
    IFS="$(printf '\t')"
    set -- $release_values
    IFS=$old_ifs
    [ "$#" -eq 4 ] || die "некорректный манифест выпуска"
    RELEASE_VERSION=$1
    RELEASE_COMMIT=$2
    RELEASE_WATCHDOG_SHA256=$3
    RELEASE_MANAGER_SHA256=$4
    [ "$RELEASE_VERSION" = "$VERSION" ] || \
        die "манифест имеет версию $RELEASE_VERSION, ожидалась $VERSION"
}

validate_sha256() {
    calculated=$("$SHA256_BIN" "$1" 2>/dev/null | awk 'NR == 1 { print $1; exit }') || \
        die "не удалось вычислить SHA-256 $3"
    [ "$calculated" = "$2" ] || die "SHA-256 $3 не совпадает с манифестом"
}

validate_download_size() {
    downloaded_size=$(wc -c < "$1") || die "не удалось проверить размер $3"
    [ "$downloaded_size" -gt 0 ] && [ "$downloaded_size" -le "$2" ] || \
        die "недопустимый размер $3"
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

ensure_dependencies() {
    missing_packages=""
    command -v "$NDMC_BIN" >/dev/null 2>&1 || missing_packages="ndmq"
    [ -x "$CRON_INIT" ] || missing_packages="$missing_packages cron"
    if [ -n "$missing_packages" ]; then
        say "Устанавливаю необходимые пакеты:$missing_packages"
        "$OPKG_BIN" update || die "не удалось обновить список пакетов Entware"
        # Only fixed package names assembled above, never user input.
        "$OPKG_BIN" install $missing_packages || die "не удалось установить зависимости"
    fi
    command -v "$NDMC_BIN" >/dev/null 2>&1 || die "после установки команда ndmc не найдена"
    [ -x "$CRON_INIT" ] || die "после установки служба cron не найдена"
    if grep -q '^ENABLED=no' "$CRON_INIT" 2>/dev/null; then
        sed -i 's/^ENABLED=no/ENABLED=yes/' "$CRON_INIT" || \
            die "не удалось включить автозапуск cron"
    fi
    if ! "$PIDOF_BIN" cron >/dev/null 2>&1; then
        "$CRON_INIT" start >/dev/null 2>&1 || die "не удалось запустить cron"
        "$PIDOF_BIN" cron >/dev/null 2>&1 || die "процесс cron не запущен"
    fi
}

show_summary() {
    run_command=$MANAGER_PATH
    if [ -L "$SHORT_COMMAND" ] && [ "$(readlink "$SHORT_COMMAND" 2>/dev/null)" = "$MANAGER_PATH" ]; then
        run_command=wgwm
    fi
    say ""
    say "WG Watchdog Manager $VERSION установлен."
    say ""
    say "Установлено:"
    say "  Менеджер:  $MANAGER_PATH"
    say "  Watchdog:  $WATCHDOG_PATH"
    if [ "$run_command" = "wgwm" ]; then
        say "  Команда:   wgwm"
    else
        say "  Запуск:    $MANAGER_PATH"
    fi
    say ""
    say "Дальнейшие действия:"
    say "  Запустить и настроить:  $run_command"
    say "  Принудительно переустановить:"
    say "    wget -qO- $BASE_URL/install.sh | sh -s -- --force"
    say "  Удалить программу:      $run_command --uninstall"
    say "  Обычный текстовый режим: $run_command --plain"
    say ""
    say "Зависимости ndmq и cron проверены; cron запущен и включён в автозапуск."
}

case "${1:-}" in
    '') ;;
    -force|--force) FORCE_INSTALL=yes ;;
    -h|--help)
        say "Использование: install.sh [--force]"
        say "Без ключа установленная программа просто запускается; --force переустанавливает файлы."
        exit 0
        ;;
    *) die "неизвестный параметр: $1" ;;
esac
[ "$#" -le 1 ] || die "укажите не более одного параметра"

[ "$(id -u 2>/dev/null)" = "0" ] || die "запустите установщик от пользователя root"
[ -d "$OPT_ROOT" ] || die "каталог $OPT_ROOT отсутствует — сначала установите Entware"
command -v "$OPKG_BIN" >/dev/null 2>&1 || die "команда opkg не найдена — Entware не запущен"
[ -r "$INPUT_DEVICE" ] && [ -w "$OUTPUT_DEVICE" ] || die "установщик нужно запускать из интерактивного терминала"
mkdir -p "$OPT_ROOT/bin" "$TMP_DIR" || die "не удалось подготовить каталог $OPT_ROOT/bin"

# Повторный запуск установщика открывает уже установленный менеджер.
if [ "$FORCE_INSTALL" != "yes" ] && [ -x "$MANAGER_PATH" ] && [ -x "$WATCHDOG_PATH" ] && \
   grep -q '^AUTHOR="org1org"$' "$MANAGER_PATH" 2>/dev/null; then
    exec "$MANAGER_PATH"
    die "не удалось запустить установленный менеджер"
fi

FIRST_INSTALL=no
if [ ! -e "$MANAGER_PATH" ] && [ ! -e "$WATCHDOG_PATH" ]; then
    FIRST_INSTALL=yes
fi
if [ "$FIRST_INSTALL" = "yes" ] && [ "$FORCE_INSTALL" != "yes" ]; then
    say "WG Watchdog Manager контролирует доступность WG-сервера и перезапускает"
    say "зависший WireGuard-интерфейс по заданным правилам."
    confirm_yes "Установить WG Watchdog Manager?" || {
        say "Установка отменена."
        exit 0
    }
fi

make_temp watchdog
tmp_watchdog=$REPLY
make_temp manager
tmp_manager=$REPLY

command -v "$SHA256_BIN" >/dev/null 2>&1 || die "команда sha256sum не найдена"
fetch_release_manifest
release_url="$RAW_REPOSITORY_URL/$RELEASE_COMMIT"
say "Загружаю WG Watchdog Manager $VERSION..."
download_file "$release_url/wg-watchdog.sh" "$tmp_watchdog" || die "не удалось загрузить watchdog"
download_file "$release_url/wg-watchdog-manager.sh" "$tmp_manager" || die "не удалось загрузить менеджер"
validate_download_size "$tmp_watchdog" 131072 watchdog
validate_download_size "$tmp_manager" 262144 менеджера
sh -n "$tmp_watchdog" || die "ошибка синтаксиса в загруженном watchdog"
sh -n "$tmp_manager" || die "ошибка синтаксиса в загруженном менеджере"
validate_script_version "$tmp_watchdog" watchdog
validate_script_version "$tmp_manager" менеджер
validate_sha256 "$tmp_watchdog" "$RELEASE_WATCHDOG_SHA256" watchdog
validate_sha256 "$tmp_manager" "$RELEASE_MANAGER_SHA256" менеджера
ensure_dependencies

if [ "$FORCE_INSTALL" = yes ] && [ -f "$WATCHDOG_PATH" ] && [ ! -L "$WATCHDOG_PATH" ] && \
   [ -f "$MANAGER_PATH" ] && [ ! -L "$MANAGER_PATH" ]; then
    WG_WATCHDOG_LIB_ONLY=no sh "$tmp_manager" --repair || \
        die "безопасная переустановка не завершена"
    ensure_short_command
    show_summary
    exit 0
fi

install_if_changed "$tmp_watchdog" "$WATCHDOG_PATH"
install_if_changed "$tmp_manager" "$MANAGER_PATH"
ensure_short_command
show_summary
exit 0
