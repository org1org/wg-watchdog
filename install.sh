#!/bin/sh

VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/org1org/wg-watchdog/main/wg-watchdog.sh"
INSTALL_PATH="/opt/bin/wg-watchdog.sh"
CONFIG_PATH="/opt/etc/wg-watchdog.conf"
CRONTAB_PATH="/opt/etc/crontab"
CRON_LINE="*/5 * * * * root /opt/bin/wg-watchdog.sh"
TTY_DEVICE="${WG_WATCHDOG_TTY:-/dev/tty}"
PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

cleanup() {
    [ -n "${TMP_SCRIPT:-}" ] && rm -f "$TMP_SCRIPT"
    [ -n "${TMP_CRONTAB:-}" ] && rm -f "$TMP_CRONTAB"
}
trap cleanup EXIT HUP INT TERM

say() { printf '%s\n' "$*"; }
die() { say "Ошибка: $*" >&2; exit 1; }

read_answer() {
    prompt=$1
    default_value=$2
    printf '%s [%s]: ' "$prompt" "$default_value" > "$TTY_DEVICE"
    IFS= read -r answer < "$TTY_DEVICE" || die "не удалось прочитать ответ"
    [ -n "$answer" ] || answer=$default_value
    REPLY=$answer
}

confirm() {
    printf '%s [д/Н]: ' "$1" > "$TTY_DEVICE"
    IFS= read -r answer < "$TTY_DEVICE" || die "не удалось прочитать ответ"
    case "$answer" in
        д|Д|да|Да|ДА|y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0) return 1 ;;
        *) return 0 ;;
    esac
}

ask_positive_integer() {
    variable_name=$1
    prompt=$2
    default_value=$3
    while :; do
        read_answer "$prompt" "$default_value"
        if is_positive_integer "$REPLY"; then
            eval "$variable_name=\$REPLY"
            return 0
        fi
        say "Введите целое число больше нуля."
    done
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

say ""
say "WG Watchdog для KeeneticOS + Entware, версия $VERSION"
say ""
say "Скрипт контролирует доступность центрального WireGuard-сервера."
say "Если интернет работает, но сервер через туннель не отвечает,"
say "WireGuard-интерфейс пира автоматически перезапускается."
say "Проверка выполняется cron каждые 5 минут."
say ""

[ -r "$TTY_DEVICE" ] || die "установщик нужно запускать из интерактивного терминала"
[ "$(id -u 2>/dev/null)" = "0" ] || die "запустите установщик от пользователя root"
[ -d /opt ] || die "каталог /opt отсутствует — сначала установите и запустите Entware"
command -v opkg >/dev/null 2>&1 || die "команда opkg не найдена — Entware не запущен"

if ! command -v ndmc >/dev/null 2>&1; then
    say "Устанавливаю ndmq для управления интерфейсами KeeneticOS..."
    opkg update || die "не удалось обновить список пакетов Entware"
    opkg install ndmq || die "не удалось установить пакет ndmq"
fi

say "Найдены следующие WireGuard-интерфейсы:"
RUNNING_CONFIG=$(ndmc -c "show running-config" 2>/dev/null || true)
INTERFACE_LIST=$(printf '%s\n' "$RUNNING_CONFIG" | awk '
    function output() {
        if (is_wg) {
            if (description == "") description = "без описания"
            print interface_name "\t" description
        }
    }
    $1 == "interface" {
        output()
        interface_name = $2
        is_wg = (interface_name ~ /^Wireguard[0-9]+$/)
        description = ""
        next
    }
    is_wg && $1 == "description" {
        sub(/^[[:space:]]*description[[:space:]]+/, "")
        description = $0
        gsub(/^"|"$/, "", description)
    }
    END { output() }
')

if [ -n "$INTERFACE_LIST" ]; then
    index=1
    printf '%s\n' "$INTERFACE_LIST" | while IFS="$(printf '\t')" read -r iface description; do
        printf '  %s) %s — %s\n' "$index" "$iface" "$description"
        index=$((index + 1))
    done
    interface_count=$(printf '%s\n' "$INTERFACE_LIST" | awk 'NF { count++ } END { print count + 0 }')
    while :; do
        read_answer "Выберите номер WireGuard-интерфейса" "1"
        if is_positive_integer "$REPLY" && [ "$REPLY" -le "$interface_count" ]; then
            WG_INTERFACE=$(printf '%s\n' "$INTERFACE_LIST" | sed -n "${REPLY}p" | cut -f1)
            break
        fi
        say "Введите номер от 1 до $interface_count."
    done
else
    say "  Автоматически определить интерфейсы не удалось."
    read_answer "Введите системное имя WireGuard-интерфейса" "Wireguard0"
    WG_INTERFACE=$REPLY
fi

case "$WG_INTERFACE" in
    Wireguard*)
        interface_number=${WG_INTERFACE#Wireguard}
        case "$interface_number" in
            ''|*[!0-9]*) die "недопустимое имя интерфейса: $WG_INTERFACE" ;;
        esac
        ;;
    *) die "недопустимое имя интерфейса: $WG_INTERFACE" ;;
esac

while :; do
    printf 'Введите внутренний IP-адрес WireGuard-сервера: ' > "$TTY_DEVICE"
    IFS= read -r WG_SERVER_TUNNEL_IP < "$TTY_DEVICE" || die "не удалось прочитать адрес"
    case "$WG_SERVER_TUNNEL_IP" in
        '') say "Адрес не может быть пустым." ;;
        *[!0-9A-Za-z.:-]*) say "В адресе присутствуют недопустимые символы." ;;
        *) break ;;
    esac
done

say "Проверяю связь с $WG_SERVER_TUNNEL_IP..."
if ping -c 3 -W 3 "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
    say "Сервер отвечает на ping."
else
    say "Сервер не ответил на ping. Возможно, ICMP запрещён или туннель сейчас не работает."
    confirm "Продолжить настройку несмотря на отсутствие ответа?" || die "установка отменена пользователем"
fi

say ""
say "Настройка параметров проверки. Нажмите Enter, чтобы принять значение в скобках."
ask_positive_integer PING_COUNT "PING_COUNT — число ping-запросов при проверке" "3"
ask_positive_integer PING_TIMEOUT "PING_TIMEOUT — ожидание каждого ответа, секунд" "3"
ask_positive_integer RESTART_DELAY "RESTART_DELAY — пауза между выключением и включением WG, секунд" "3"

say ""
say "Будут применены настройки:"
say "  Интерфейс:         $WG_INTERFACE"
say "  WG-сервер:         $WG_SERVER_TUNNEL_IP"
say "  Число ping:        $PING_COUNT"
say "  Ожидание ping:     $PING_TIMEOUT сек."
say "  Пауза перезапуска: $RESTART_DELAY сек."
say ""

mkdir -p /opt/bin /opt/etc /opt/var/run /opt/tmp || die "не удалось создать каталоги в /opt"
TMP_SCRIPT="/opt/tmp/wg-watchdog.sh.$$"

say "Загружаю watchdog..."
download_file "$SCRIPT_URL" "$TMP_SCRIPT" || die "не удалось загрузить $SCRIPT_URL"
sh -n "$TMP_SCRIPT" || die "загруженный watchdog содержит синтаксическую ошибку"
chmod 755 "$TMP_SCRIPT" || die "не удалось установить права на watchdog"
mv "$TMP_SCRIPT" "$INSTALL_PATH" || die "не удалось установить $INSTALL_PATH"
TMP_SCRIPT=""

cat > "$CONFIG_PATH" <<EOF
# Создано установщиком wg-watchdog $VERSION
WG_INTERFACE='$WG_INTERFACE'
WG_SERVER_TUNNEL_IP='$WG_SERVER_TUNNEL_IP'
PING_COUNT='$PING_COUNT'
PING_TIMEOUT='$PING_TIMEOUT'
RESTART_DELAY='$RESTART_DELAY'
EOF
chmod 600 "$CONFIG_PATH" || die "не удалось установить права на $CONFIG_PATH"

if [ ! -x /opt/etc/init.d/S10cron ]; then
    say "Устанавливаю cron..."
    opkg update || die "не удалось обновить список пакетов Entware"
    opkg install cron || die "не удалось установить cron"
fi

if grep -q '^ENABLED=no' /opt/etc/init.d/S10cron 2>/dev/null; then
    sed -i 's/^ENABLED=no/ENABLED=yes/' /opt/etc/init.d/S10cron || die "не удалось включить автозапуск cron"
fi

TMP_CRONTAB="/opt/tmp/crontab.$$"
if [ -f "$CRONTAB_PATH" ]; then
    awk '!/\/opt\/bin\/wg-watchdog\.sh/' "$CRONTAB_PATH" > "$TMP_CRONTAB" || die "не удалось обновить crontab"
else
    : > "$TMP_CRONTAB" || die "не удалось создать crontab"
fi
printf '%s\n' "$CRON_LINE" >> "$TMP_CRONTAB" || die "не удалось добавить задание cron"
mv "$TMP_CRONTAB" "$CRONTAB_PATH" || die "не удалось сохранить crontab"
TMP_CRONTAB=""

/opt/etc/init.d/S10cron restart >/dev/null 2>&1 || die "не удалось запустить cron"

say "Выполняю итоговую проверку..."
sh -n "$INSTALL_PATH" || die "ошибка синтаксиса в установленном watchdog"
grep -F "$CRON_LINE" "$CRONTAB_PATH" >/dev/null 2>&1 || die "задание не найдено в crontab"
pidof cron >/dev/null 2>&1 || die "процесс cron не запущен"

say ""
say "Установка завершена."
say "  Скрипт:    $INSTALL_PATH"
say "  Настройки: $CONFIG_PATH"
say "  Запуск:    каждые 5 минут"
say ""
say "Ручная проверка: $INSTALL_PATH"
say "Сообщения: logread | grep wg-watchdog"

exit 0
