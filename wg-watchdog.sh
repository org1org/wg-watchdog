#!/bin/sh

# WG Watchdog for KeeneticOS + Entware

VERSION="1.8.4"
CONFIG_DIR="${WG_WATCHDOG_CONFIG_DIR:-/opt/etc/wg-watchdog.d}"
STATE_DIR="${WG_WATCHDOG_STATE_DIR:-/tmp/wg-watchdog}"
RUN_DIR="${WG_WATCHDOG_RUN_DIR:-/tmp/wg-watchdog}"
BOOT_ID_FILE="${WG_WATCHDOG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
UPTIME_FILE="${WG_WATCHDOG_UPTIME_FILE:-/proc/uptime}"
PING_BIN="${WG_WATCHDOG_PING:-ping}"
NDMC_BIN="${WG_WATCHDOG_NDMC:-ndmc}"
LOGGER_BIN="${WG_WATCHDOG_LOGGER:-logger}"
SLEEP_BIN="${WG_WATCHDOG_SLEEP:-sleep}"
PATH="${WG_WATCHDOG_PATH:-/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

FORCE=no
LOCK_ACQUIRED=no
INTERFACE_NEEDS_UP=no
umask 077
STATE_TMP=""

say() {
    [ "$FORCE" = "yes" ] && printf '%s\n' "$*"
    return 0
}

log_message() {
    "$LOGGER_BIN" -t wg-watchdog "$*" 2>/dev/null || true
    say "$*"
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0|0[0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_nonnegative_integer() {
    case "$1" in
        ''|*[!0-9]*|0[0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_integer_between() {
    is_positive_integer "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

valid_address() {
    case "$1" in
        ''|*[!0-9A-Za-z.:-]*) return 1 ;;
        *[0-9A-Za-z]*) return 0 ;;
        *) return 1 ;;
    esac
}

load_config() {
    JOB_ID=""
    WG_INTERFACE=""
    WG_SERVER_TUNNEL_IP=""
    WG_SERVER_PUBLIC_IP=""
    PING_COUNT=""
    PING_TIMEOUT=""
    RESTART_DELAY=""
    CHECK_INTERVAL=""
    INTERNET_CHECK=""
    INTERNET_CHECK_TARGET_1=""
    INTERNET_CHECK_TARGET_2=""
    FAILURE_THRESHOLD=""
    RESTART_COOLDOWN=""
    BOOT_GRACE=""
    RECOVERY_CHECK_DELAY=""
    ENABLED=""
    [ -r "$CONFIG_FILE" ] || return 1
    config_seen="|"
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        case "$config_line" in
            ''|\#*) continue ;;
        esac
        config_key=${config_line%%=*}
        config_raw=${config_line#*=}
        [ "$config_key" != "$config_line" ] || return 1
        case "$config_raw" in
            \'*\') config_value=${config_raw#\'}; config_value=${config_value%\'} ;;
            \"*\") config_value=${config_raw#\"}; config_value=${config_value%\"} ;;
            *) config_value=$config_raw ;;
        esac
        case "$config_value" in *[!0-9A-Za-z.:-]*) return 1 ;; esac
        case "$config_seen" in *"|$config_key|"*) return 1 ;; esac
        config_seen="${config_seen}${config_key}|"
        case "$config_key" in
            JOB_ID) JOB_ID=$config_value ;;
            WG_INTERFACE) WG_INTERFACE=$config_value ;;
            WG_SERVER_TUNNEL_IP) WG_SERVER_TUNNEL_IP=$config_value ;;
            WG_SERVER_PUBLIC_IP) WG_SERVER_PUBLIC_IP=$config_value ;;
            PING_COUNT) PING_COUNT=$config_value ;;
            PING_TIMEOUT) PING_TIMEOUT=$config_value ;;
            RESTART_DELAY) RESTART_DELAY=$config_value ;;
            CHECK_INTERVAL) CHECK_INTERVAL=$config_value ;;
            INTERNET_CHECK) INTERNET_CHECK=$config_value ;;
            INTERNET_CHECK_TARGET_1) INTERNET_CHECK_TARGET_1=$config_value ;;
            INTERNET_CHECK_TARGET_2) INTERNET_CHECK_TARGET_2=$config_value ;;
            FAILURE_THRESHOLD) FAILURE_THRESHOLD=$config_value ;;
            RESTART_COOLDOWN) RESTART_COOLDOWN=$config_value ;;
            BOOT_GRACE) BOOT_GRACE=$config_value ;;
            RECOVERY_CHECK_DELAY) RECOVERY_CHECK_DELAY=$config_value ;;
            ENABLED) ENABLED=$config_value ;;
            *) return 1 ;;
        esac
    done < "$CONFIG_FILE"
    return 0
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

release_lock() {
    [ "$LOCK_ACQUIRED" = "yes" ] || return 0
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_ACQUIRED=no
}

cleanup() {
    if [ "$INTERFACE_NEEDS_UP" = "yes" ]; then
        if "$NDMC_BIN" -c "interface $WG_INTERFACE up" >/dev/null 2>&1; then
            INTERFACE_NEEDS_UP=no
        else
            log_message "[$JOB_ID] аварийное включение $WG_INTERFACE не удалось; требуется проверка вручную"
        fi
    fi
    [ -n "$STATE_TMP" ] && rm -f "$STATE_TMP"
    release_lock
}

acquire_lock() {
    mkdir -p "$RUN_DIR" || return 1
    [ ! -d "$RUN_DIR/maintenance.lock" ] || return 2
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
            rmdir "$LOCK_DIR" 2>/dev/null || true
            return 1
        fi
        LOCK_ACQUIRED=yes
        return 0
    fi

    reclaim_stale_lock || return 2
    LOCK_ACQUIRED=yes
    return 0
}

reclaim_stale_lock() (
    # Serialize reclamation; an absent PID may belong to a new writer.
    mkdir "$RUN_DIR/recovery.lock" 2>/dev/null || exit 1
    trap 'rmdir "$RUN_DIR/recovery.lock" 2>/dev/null || true' EXIT
    [ ! -d "$RUN_DIR/maintenance.lock" ] || exit 1
    [ ! -L "$LOCK_DIR" ] || exit 1
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    is_positive_integer "$old_pid" || exit 1
    kill -0 "$old_pid" 2>/dev/null && exit 1
    rm -f "$LOCK_DIR/pid" && rmdir "$LOCK_DIR" && mkdir "$LOCK_DIR" || exit 1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
)

current_text_time() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'неизвестно'
}

reset_state() {
    STATE_BOOT_ID=$CURRENT_BOOT_ID
    CONSECUTIVE_FAILURES=0
    LAST_CHECK_EPOCH=0
    LAST_CHECK_TEXT="никогда"
    LAST_SUCCESS_TEXT="никогда"
    LAST_RESTART_EPOCH=0
    LAST_RESTART_UPTIME=0
    LAST_RESTART_TEXT="никогда"
    LAST_RESULT="ещё не проверялось"
}

load_state() {
    reset_state
    [ -r "$STATE_FILE" ] || return 0
    # Файл создаётся этим скриптом с правами 600.
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    is_nonnegative_integer "${CONSECUTIVE_FAILURES:-}" || CONSECUTIVE_FAILURES=0
    is_nonnegative_integer "${LAST_CHECK_EPOCH:-}" || LAST_CHECK_EPOCH=0
    is_nonnegative_integer "${LAST_RESTART_EPOCH:-}" || LAST_RESTART_EPOCH=0
    is_nonnegative_integer "${LAST_RESTART_UPTIME:-}" || LAST_RESTART_UPTIME=0
    if [ "${STATE_BOOT_ID:-}" != "$CURRENT_BOOT_ID" ]; then
        reset_state
    fi
}

save_state() {
    mkdir -p "$STATE_DIR" || return 1
    STATE_TMP="$STATE_FILE.$$"
    umask 077
    {
        printf "STATE_BOOT_ID='%s'\n" "$STATE_BOOT_ID"
        printf "CONSECUTIVE_FAILURES='%s'\n" "$CONSECUTIVE_FAILURES"
        printf "LAST_CHECK_EPOCH='%s'\n" "$LAST_CHECK_EPOCH"
        printf "LAST_CHECK_TEXT='%s'\n" "$LAST_CHECK_TEXT"
        printf "LAST_SUCCESS_TEXT='%s'\n" "$LAST_SUCCESS_TEXT"
        printf "LAST_RESTART_EPOCH='%s'\n" "$LAST_RESTART_EPOCH"
        printf "LAST_RESTART_UPTIME='%s'\n" "$LAST_RESTART_UPTIME"
        printf "LAST_RESTART_TEXT='%s'\n" "$LAST_RESTART_TEXT"
        printf "LAST_RESULT='%s'\n" "$LAST_RESULT"
    } > "$STATE_TMP" || return 1
    mv "$STATE_TMP" "$STATE_FILE" || return 1
    STATE_TMP=""
}

record_result() {
    LAST_RESULT=$1
    LAST_CHECK_EPOCH=$NOW_EPOCH
    LAST_CHECK_TEXT=$(current_text_time)
    save_state || log_message "[$JOB_ID] не удалось сохранить состояние"
}

record_transition() {
    new_result=$1
    transition_message=$2
    previous_result=$LAST_RESULT
    record_result "$new_result"
    if [ "$previous_result" != "$new_result" ]; then
        log_message "$transition_message"
    else
        # Manual checks always explain their result without duplicating syslog.
        say "$transition_message"
    fi
}

ping_target() {
    "$PING_BIN" -c "$1" -W "$PING_TIMEOUT" "$2" >/dev/null 2>&1
}

if [ "${1:-}" != "--job" ] || [ -z "${2:-}" ] || [ -n "${4:-}" ]; then
    usage >&2
    exit 2
fi

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
STATE_FILE="$STATE_DIR/$REQUESTED_JOB.state"
LOCK_DIR="$RUN_DIR/wg-watchdog-$REQUESTED_JOB.lock"

[ ! -d "$RUN_DIR/maintenance.lock" ] || exit 0
[ ! -e "$RUN_DIR/uninstalled" ] || exit 0

if [ ! -r "$CONFIG_FILE" ]; then
    log_message "[$REQUESTED_JOB] не найден файл настроек $CONFIG_FILE"
    exit 1
fi

if ! load_config; then
    log_message "[$REQUESTED_JOB] файл настроек имеет недопустимый формат"
    exit 1
fi

: "${FAILURE_THRESHOLD:=2}"
: "${RESTART_COOLDOWN:=30}"
: "${BOOT_GRACE:=180}"
: "${RECOVERY_CHECK_DELAY:=15}"
: "${WG_SERVER_PUBLIC_IP:=}"
: "${INTERNET_CHECK:=yes}"
: "${INTERNET_CHECK_TARGET_1:=1.1.1.1}"
: "${INTERNET_CHECK_TARGET_2:=8.8.8.8}"

if [ "${ENABLED:-no}" != "yes" ] && [ "$FORCE" != "yes" ]; then
    exit 0
fi

if [ "${JOB_ID:-}" != "$REQUESTED_JOB" ] || \
   [ "${WG_INTERFACE:-}" != "$REQUESTED_JOB" ] || \
   ! valid_address "${WG_SERVER_TUNNEL_IP:-}" || \
   { [ -n "${WG_SERVER_PUBLIC_IP:-}" ] && ! valid_address "$WG_SERVER_PUBLIC_IP"; }; then
    log_message "[$REQUESTED_JOB] файл настроек повреждён или не соответствует заданию"
    exit 1
fi

is_integer_between "$PING_COUNT" 1 10 && \
is_integer_between "$PING_TIMEOUT" 1 30 && \
is_integer_between "$RESTART_DELAY" 1 60 && \
is_integer_between "$FAILURE_THRESHOLD" 1 10 && \
is_integer_between "$RESTART_COOLDOWN" 1 1440 && \
is_integer_between "$BOOT_GRACE" 1 3600 && \
is_integer_between "$RECOVERY_CHECK_DELAY" 1 300 || {
    log_message "[$JOB_ID] в настройках найдено недопустимое числовое значение"
    exit 1
}
case "$CHECK_INTERVAL" in
    1|2|3|4|5|6|10|12|15|20|30|60) ;;
    *) log_message "[$JOB_ID] в настройках найден недопустимый интервал проверки"; exit 1 ;;
esac
case "$INTERNET_CHECK" in
    yes|no) ;;
    *) log_message "[$JOB_ID] в настройках найден недопустимый режим проверки интернета"; exit 1 ;;
esac
valid_address "$INTERNET_CHECK_TARGET_1" && \
valid_address "$INTERNET_CHECK_TARGET_2" || {
    log_message "[$JOB_ID] контрольные адреса интернета имеют недопустимый формат"
    exit 1
}

acquire_lock
lock_result=$?
case "$lock_result" in
    0) ;;
    2) exit 0 ;;
    *) log_message "[$JOB_ID] не удалось создать блокировку"; exit 1 ;;
esac
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Close the race between the initial maintenance check and mkdir.
[ ! -d "$RUN_DIR/maintenance.lock" ] || exit 0
[ ! -e "$RUN_DIR/uninstalled" ] || exit 0
[ -r "$CONFIG_FILE" ] || exit 0

CURRENT_BOOT_ID=$(sed -n '1p' "$BOOT_ID_FILE" 2>/dev/null)
[ -n "$CURRENT_BOOT_ID" ] || CURRENT_BOOT_ID="unknown"
NOW_EPOCH=$(date +%s 2>/dev/null)
is_nonnegative_integer "$NOW_EPOCH" || NOW_EPOCH=0
CURRENT_UPTIME=$(sed -n '1s/\..*//p' "$UPTIME_FILE" 2>/dev/null)
if is_nonnegative_integer "$CURRENT_UPTIME"; then
    UPTIME_AVAILABLE=yes
else
    CURRENT_UPTIME=0
    UPTIME_AVAILABLE=no
fi
load_state

if [ "$UPTIME_AVAILABLE" = yes ] && [ "$CURRENT_UPTIME" -lt "$BOOT_GRACE" ]; then
    CONSECUTIVE_FAILURES=0
    record_transition "пауза после загрузки роутера" \
        "[$JOB_ID] после загрузки прошло ${CURRENT_UPTIME}с — проверка отложена"
    exit 0
fi

# Если обычный интернет недоступен, перезапуск туннеля не поможет.
if [ "$INTERNET_CHECK" = yes ] && \
   ! ping_target 1 "$INTERNET_CHECK_TARGET_1" && \
   ! ping_target 1 "$INTERNET_CHECK_TARGET_2"; then
    CONSECUTIVE_FAILURES=0
    record_transition "обычный интернет недоступен" \
        "[$JOB_ID] интернет недоступен — перезапуск $WG_INTERFACE пропущен"
    exit 0
fi

# Необязательная проверка отличает отключённый сервер от зависшего туннеля.
if [ -n "$WG_SERVER_PUBLIC_IP" ] && ! ping_target 1 "$WG_SERVER_PUBLIC_IP"; then
    CONSECUTIVE_FAILURES=0
    record_transition "публичный адрес WG-сервера недоступен" \
        "[$JOB_ID] WG-сервер $WG_SERVER_PUBLIC_IP недоступен снаружи — перезапуск пропущен"
    exit 0
fi

if ping_target "$PING_COUNT" "$WG_SERVER_TUNNEL_IP"; then
    CONSECUTIVE_FAILURES=0
    LAST_SUCCESS_TEXT=$(current_text_time)
    record_result "туннель работает"
    say "[$JOB_ID] $WG_SERVER_TUNNEL_IP доступен — туннель работает"
    exit 0
fi

CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
if [ "$CONSECUTIVE_FAILURES" -lt "$FAILURE_THRESHOLD" ]; then
    record_result "ошибка связи $CONSECUTIVE_FAILURES из $FAILURE_THRESHOLD"
    log_message "[$JOB_ID] $WG_SERVER_TUNNEL_IP недоступен: ошибка $CONSECUTIVE_FAILURES из $FAILURE_THRESHOLD"
    exit 0
fi

cooldown_seconds=$((RESTART_COOLDOWN * 60))
since_restart=-1
if [ "$CURRENT_UPTIME" -gt 0 ] && [ "$LAST_RESTART_UPTIME" -gt 0 ]; then
    since_restart=$((CURRENT_UPTIME - LAST_RESTART_UPTIME))
elif [ "$NOW_EPOCH" -gt 0 ] && [ "$LAST_RESTART_EPOCH" -gt 0 ]; then
    since_restart=$((NOW_EPOCH - LAST_RESTART_EPOCH))
    # A backward wall-clock correction must not bypass cooldown.
    [ "$since_restart" -ge 0 ] || since_restart=0
fi
if [ "$since_restart" -ge 0 ]; then
    if [ "$since_restart" -lt "$cooldown_seconds" ]; then
        remaining=$(((cooldown_seconds - since_restart + 59) / 60))
        CONSECUTIVE_FAILURES=$FAILURE_THRESHOLD
        record_transition "cooldown после перезапуска" \
            "[$JOB_ID] действует cooldown — следующий перезапуск не раньше чем через $remaining мин."
        exit 0
    fi
fi

LAST_RESTART_EPOCH=$NOW_EPOCH
LAST_RESTART_UPTIME=$CURRENT_UPTIME
LAST_RESTART_TEXT=$(current_text_time)
CONSECUTIVE_FAILURES=$FAILURE_THRESHOLD
record_result "перезапуск интерфейса"
log_message "[$JOB_ID] $WG_SERVER_TUNNEL_IP недоступен — перезапускаю $WG_INTERFACE"

INTERFACE_NEEDS_UP=yes
if ! "$NDMC_BIN" -c "interface $WG_INTERFACE down" >/dev/null 2>&1; then
    record_result "ошибка выключения интерфейса"
    log_message "[$JOB_ID] не удалось выключить $WG_INTERFACE"
    exit 1
fi

"$SLEEP_BIN" "$RESTART_DELAY"

if ! "$NDMC_BIN" -c "interface $WG_INTERFACE up" >/dev/null 2>&1; then
    record_result "ошибка включения интерфейса"
    log_message "[$JOB_ID] не удалось включить $WG_INTERFACE"
    exit 1
fi

INTERFACE_NEEDS_UP=no
"$SLEEP_BIN" "$RECOVERY_CHECK_DELAY"
if ping_target "$PING_COUNT" "$WG_SERVER_TUNNEL_IP"; then
    CONSECUTIVE_FAILURES=0
    LAST_SUCCESS_TEXT=$(current_text_time)
    record_result "туннель восстановлен"
    log_message "[$JOB_ID] $WG_INTERFACE успешно восстановлен"
else
    record_result "интерфейс перезапущен, туннель пока недоступен"
    log_message "[$JOB_ID] $WG_INTERFACE перезапущен, но $WG_SERVER_TUNNEL_IP пока недоступен"
fi

exit 0
