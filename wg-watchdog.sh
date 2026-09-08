#!/bin/sh

# wg-watchdog for KeeneticOS + Entware

CONFIG_FILE="/opt/etc/wg-watchdog.conf"
LOCK_FILE="/opt/var/run/wg-watchdog.pid"
PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

log_message() {
    logger -t wg-watchdog "$*"
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0) return 1 ;;
        *) return 0 ;;
    esac
}

if [ ! -r "$CONFIG_FILE" ]; then
    log_message "не найден файл настроек $CONFIG_FILE"
    exit 1
fi

# Конфигурация создаётся интерактивным установщиком.
# shellcheck disable=SC1090
. "$CONFIG_FILE"

if [ -z "${WG_INTERFACE:-}" ] || [ -z "${WG_SERVER_TUNNEL_IP:-}" ]; then
    log_message "в $CONFIG_FILE не заданы WG_INTERFACE или WG_SERVER_TUNNEL_IP"
    exit 1
fi

is_positive_integer "${PING_COUNT:-}" || exit 1
is_positive_integer "${PING_TIMEOUT:-}" || exit 1
is_positive_integer "${RESTART_DELAY:-}" || exit 1

mkdir -p /opt/var/run
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null)
    if is_positive_integer "$old_pid" && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo "$$" > "$LOCK_FILE" || exit 1
trap 'rm -f "$LOCK_FILE"' EXIT HUP INT TERM

# При отсутствии обычного интернета WireGuard не перезапускаем.
if ! ping -c 1 -W "$PING_TIMEOUT" 1.1.1.1 >/dev/null 2>&1 && \
   ! ping -c 1 -W "$PING_TIMEOUT" 8.8.8.8 >/dev/null 2>&1; then
    log_message "интернет недоступен — перезапуск $WG_INTERFACE пропущен"
    exit 0
fi

# Сервер доступен через туннель — вмешательство не требуется.
if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
    exit 0
fi

log_message "$WG_SERVER_TUNNEL_IP недоступен через $WG_INTERFACE — перезапускаю интерфейс"

if ! ndmc -c "interface $WG_INTERFACE down" >/dev/null 2>&1; then
    log_message "не удалось выключить $WG_INTERFACE"
    exit 1
fi

sleep "$RESTART_DELAY"

if ! ndmc -c "interface $WG_INTERFACE up" >/dev/null 2>&1; then
    log_message "не удалось включить $WG_INTERFACE"
    exit 1
fi

# Даём WireGuard время выполнить handshake и фиксируем результат в журнале.
sleep 5
if ping -c 1 -W "$PING_TIMEOUT" "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
    log_message "$WG_INTERFACE успешно восстановлен"
else
    log_message "$WG_INTERFACE перезапущен, но $WG_SERVER_TUNNEL_IP пока недоступен"
fi

exit 0
