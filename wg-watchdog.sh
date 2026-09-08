#!/bin/sh

# WG Watchdog for KeeneticOS + Entware

VERSION="1.1.0"
CONFIG_DIR="/opt/etc/wg-watchdog.d"
STATE_DIR="/opt/var/run"
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

valid_job_id() {
    case "$1" in
        Wireguard*)
            suffix=${1#Wireguard}
            case "$suffix" in ''|*[!0-9]*) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    return 0
}

usage() {
    printf 'Использование: %s --job WireguardN [--force]\n' "$0"
}

if [ "${1:-}" != "--job" ] || [ -z "${2:-}" ] || [ -n "${4:-}" ]; then
    usage >&2
    exit 2
fi

FORCE=no
case "${3:-}" in
    '') ;;
    --force) FORCE=yes ;;
    *) usage >&2; exit 2 ;;
esac

REQUESTED_JOB=$2
valid_job_id "$REQUESTED_JOB" || {
    log_message "недопустимый идентификатор задания: $REQUESTED_JOB"
    exit 2
}

CONFIG_FILE="$CONFIG_DIR/$REQUESTED_JOB.conf"
LOCK_FILE="$STATE_DIR/wg-watchdog-$REQUESTED_JOB.pid"

if [ ! -r "$CONFIG_FILE" ]; then
    log_message "[$REQUESTED_JOB] не найден файл настроек $CONFIG_FILE"
    exit 1
fi

# Файлы создаются менеджером и доступны для записи только root.
# shellcheck disable=SC1090
. "$CONFIG_FILE"

if [ "${ENABLED:-no}" != "yes" ] && [ "$FORCE" != "yes" ]; then
    exit 0
fi

if [ "${JOB_ID:-}" != "$REQUESTED_JOB" ] || \
   [ "${WG_INTERFACE:-}" != "$REQUESTED_JOB" ] || \
   [ -z "${WG_SERVER_TUNNEL_IP:-}" ]; then
    log_message "[$REQUESTED_JOB] файл настроек повреждён или не соответствует заданию"
    exit 1
fi

is_positive_integer "${PING_COUNT:-}" || exit 1
is_positive_integer "${PING_TIMEOUT:-}" || exit 1
is_positive_integer "${RESTART_DELAY:-}" || exit 1
is_positive_integer "${CHECK_INTERVAL:-}" || exit 1

mkdir -p "$STATE_DIR" || exit 1
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null)
    if is_positive_integer "$old_pid" && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo "$$" > "$LOCK_FILE" || exit 1
trap 'rm -f "$LOCK_FILE"' EXIT HUP INT TERM

# Если обычный интернет недоступен, перезапуск туннеля не поможет.
if ! ping -c 1 -W "$PING_TIMEOUT" 1.1.1.1 >/dev/null 2>&1 && \
   ! ping -c 1 -W "$PING_TIMEOUT" 8.8.8.8 >/dev/null 2>&1; then
    log_message "[$JOB_ID] интернет недоступен — перезапуск $WG_INTERFACE пропущен"
    exit 0
fi

if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
    exit 0
fi

log_message "[$JOB_ID] $WG_SERVER_TUNNEL_IP недоступен — перезапускаю $WG_INTERFACE"

if ! ndmc -c "interface $WG_INTERFACE down" >/dev/null 2>&1; then
    log_message "[$JOB_ID] не удалось выключить $WG_INTERFACE"
    exit 1
fi

sleep "$RESTART_DELAY"

if ! ndmc -c "interface $WG_INTERFACE up" >/dev/null 2>&1; then
    log_message "[$JOB_ID] не удалось включить $WG_INTERFACE"
    exit 1
fi

sleep 5
if ping -c 1 -W "$PING_TIMEOUT" "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
    log_message "[$JOB_ID] $WG_INTERFACE успешно восстановлен"
else
    log_message "[$JOB_ID] $WG_INTERFACE перезапущен, но $WG_SERVER_TUNNEL_IP пока недоступен"
fi

exit 0
