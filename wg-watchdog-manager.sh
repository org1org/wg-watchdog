#!/bin/sh

# Interactive WireGuard watchdog manager for KeeneticOS.

VERSION="1.0.0"
AUTHOR="org1org"
BASE_URL="https://raw.githubusercontent.com/org1org/wg-watchdog/main"
RAW_REPOSITORY_URL="${WG_WATCHDOG_RAW_REPOSITORY_URL:-https://raw.githubusercontent.com/org1org/wg-watchdog}"
RELEASE_MANIFEST_URL="${WG_WATCHDOG_RELEASE_MANIFEST_URL:-$BASE_URL/RELEASE}"
OPT_ROOT="${WG_WATCHDOG_OPT_ROOT:-/opt}"
WATCHDOG_PATH="$OPT_ROOT/bin/wg-watchdog.sh"
MANAGER_PATH="$OPT_ROOT/bin/wg-watchdog-manager"
SHORT_COMMAND="$OPT_ROOT/bin/wgwm"
CONFIG_DIR="${WG_WATCHDOG_CONFIG_DIR:-$OPT_ROOT/etc/wg-watchdog.d}"
STATE_DIR="${WG_WATCHDOG_STATE_DIR:-/tmp/wg-watchdog}"
RUN_DIR="${WG_WATCHDOG_RUN_DIR:-/tmp/wg-watchdog}"
UPDATE_DIR="${WG_WATCHDOG_UPDATE_DIR:-$OPT_ROOT/bin/.wg-watchdog-update}"
TMP_DIR="${WG_WATCHDOG_TMP_DIR:-/tmp}"
CRONTAB_PATH="$OPT_ROOT/etc/crontab"
CRON_INIT="$OPT_ROOT/etc/init.d/S10cron"
NDMC_BIN="${WG_WATCHDOG_NDMC:-ndmc}"
WATCHDOG_LOG_COMMAND="ndmc -c 'show log' | grep wg-watchdog"
PING_BIN="${WG_WATCHDOG_PING:-ping}"
PIDOF_BIN="${WG_WATCHDOG_PIDOF:-pidof}"
SHA256_BIN="${WG_WATCHDOG_SHA256:-sha256sum}"
DF_BIN="${WG_WATCHDOG_DF:-df}"
SYNC_BIN="${WG_WATCHDOG_SYNC:-sync}"
CRON_BEGIN="# BEGIN WG-WATCHDOG — managed automatically"
CRON_END="# END WG-WATCHDOG"
TTY_DEVICE="${WG_WATCHDOG_TTY:-/dev/tty}"
INPUT_DEVICE="${WG_WATCHDOG_INPUT:-$TTY_DEVICE}"
OUTPUT_DEVICE="${WG_WATCHDOG_OUTPUT:-$TTY_DEVICE}"
PATH="${WG_WATCHDOG_PATH:-/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

TMP_FILES=""
umask 077
CONSOLE_OPEN=no
UI_ACTIVE=no
UI_ROW=1
UI_ROWS=24
UI_COLS=80
MANAGER_LOCK_HELD=no
MAINTENANCE_HELD=no
MANAGER_INTERFACE_NEEDS_UP=no
MANAGER_RECOVERY_INTERFACE=""
WAIT_SECONDS=20
SLEEP_BIN=sleep

ui_size() {
    terminal_size=$(stty size <&3 2>/dev/null || true)
    set -- $terminal_size
    UI_ROWS=${1:-24}
    UI_COLS=${2:-80}
    case "$UI_ROWS:$UI_COLS" in *[!0-9:]*|0:*|*:0) UI_ROWS=24; UI_COLS=80 ;; esac
    [ "$UI_ROWS" -ge 12 ] || UI_ROWS=12
}

ui_start() {
    [ -t 1 ] && [ -t 3 ] && [ "${TERM:-dumb}" != dumb ] || return 0
    UI_ACTIVE=yes
    ui_size
    printf '\033[?1049h\033[?7l'
    ui_clear
}

ui_clear() {
    [ "$UI_ACTIVE" = yes ] || return 0
    ui_size
    printf '\033[2J\033[H'
    UI_ROW=1
}

ui_stop() {
    [ "$UI_ACTIVE" = yes ] || return 0
    printf '\033[0m\033[?7h\033[?25h\033[?1049l'
    UI_ACTIVE=no
}

ui_pause() {
    [ "$UI_ACTIVE" = yes ] || return 0
    # Keep the confirmation next to the result instead of detaching it at
    # the bottom edge of a large terminal.
    [ "$UI_ROW" -lt "$UI_ROWS" ] || UI_ROW=$((UI_ROWS - 1))
    printf '\033[%s;1H\033[2K' "$UI_ROW" >&4
    UI_ROW=$((UI_ROW + 1))
    printf '\033[%s;1H\033[2KНажмите Enter, чтобы продолжить: ' "$UI_ROW" >&4
    IFS= read -r ui_answer <&3 || exit 0
    ui_clear
}

ui_text() {
    # Word wrapping uses byte lengths conservatively on BusyBox awk.
    # Long unbroken tokens are clipped by the terminal, never split mid-UTF-8.
    wrapped_text=$(printf '%s\n' "$*" | awk -v width="$((UI_COLS - 2))" '
        NF == 0 { print ""; next }
        {
            line = ""
            for (i = 1; i <= NF; i++) {
                if (line != "" && length(line) + length($i) + 1 > width) {
                    print line; line = ""
                }
                line = line (line == "" ? "" : " ") $i
            }
            print line
        }')
    while IFS= read -r ui_line; do
        if [ "$UI_ROW" -ge "$((UI_ROWS - 2))" ]; then ui_pause; fi
        printf '\033[%s;1H\033[2K%s' "$UI_ROW" "$ui_line"
        UI_ROW=$((UI_ROW + 1))
    done <<EOF
$wrapped_text
EOF
}

ui_prompt() {
    [ "$UI_ACTIVE" = yes ] || return 0
    say "$1"
    printf '\033[%s;1H\033[2K> ' "$UI_ROW" >&4
    UI_ROW=$((UI_ROW + 1))
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_GREEN=$(printf '\033[1;32m')
    COLOR_RED=$(printf '\033[1;31m')
    COLOR_GRAY=$(printf '\033[1;90m')
    COLOR_YELLOW=$(printf '\033[1;33m')
    COLOR_CYAN=$(printf '\033[1;36m')
    COLOR_RESET=$(printf '\033[0m')
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_GRAY=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_RESET=""
fi

UPDATE_AVAILABLE=unknown
REMOTE_VERSION=""
REMOTE_COMMIT=""
REMOTE_WATCHDOG_SHA256=""
REMOTE_MANAGER_SHA256=""

cleanup() {
    printf '%s' "$TMP_FILES" | while IFS= read -r file; do
        [ -n "$file" ] && rm -f "$file"
    done
    TMP_FILES=""
}
finish() {
    cleanup
    if [ "$MANAGER_INTERFACE_NEEDS_UP" = yes ] && [ -n "$MANAGER_RECOVERY_INTERFACE" ]; then
        "$NDMC_BIN" -c "interface $MANAGER_RECOVERY_INTERFACE up" >/dev/null 2>&1 || true
        MANAGER_INTERFACE_NEEDS_UP=no
    fi
    end_maintenance
    release_manager_lock
    ui_stop
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

release_manager_lock() {
    [ "$MANAGER_LOCK_HELD" = yes ] || return 0
    rm -f "$RUN_DIR/manager.lock/pid"
    rmdir "$RUN_DIR/manager.lock" 2>/dev/null || true
    MANAGER_LOCK_HELD=no
}

run_visible() {
    if [ "$UI_ACTIVE" != yes ]; then "$@"; return $?; fi
    make_temp command-output
    command_output=$REPLY
    command_result=0
    "$@" > "$command_output" 2>&1 || command_result=$?
    while IFS= read -r output_line; do say "$output_line"; done < "$command_output"
    rm -f "$command_output"
    return "$command_result"
}

say() {
    if [ "$UI_ACTIVE" = yes ]; then ui_text "$*"; else printf '%s\n' "$*"; fi
}
info() { say "${COLOR_GREEN}$*${COLOR_RESET}"; }
warn() { say "${COLOR_YELLOW}ВНИМАНИЕ: $*${COLOR_RESET}"; }

result_card() {
    result_kind=$1
    result_title=$2
    result_detail=${3:-}
    result_next=${4:-}
    case "$result_kind" in
        success) result_label="ГОТОВО"; result_color=$COLOR_GREEN ;;
        warning) result_label="ВНИМАНИЕ"; result_color=$COLOR_YELLOW ;;
        error) result_label="ОШИБКА"; result_color=$COLOR_RED ;;
        cancelled) result_label="ОТМЕНЕНО"; result_color=$COLOR_GRAY ;;
        *) return 1 ;;
    esac
    say ""
    say "${result_color}${result_label}: $result_title${COLOR_RESET}"
    [ -z "$result_detail" ] || say "  $result_detail"
    [ -z "$result_next" ] || say "  Далее: $result_next"
}

die() { ui_stop; printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

open_console() {
    if [ "$CONSOLE_OPEN" = "yes" ]; then
        exec 3<&-
        exec 4>&-
    fi
    exec 3< "$INPUT_DEVICE" || die "не удалось открыть ввод терминала"
    exec 4> "$OUTPUT_DEVICE" || die "не удалось открыть вывод терминала"
    CONSOLE_OPEN=yes
}

make_temp() {
    tmp_file=$(mktemp "$TMP_DIR/wg-watchdog.$1.XXXXXX") || die "не удалось создать временный файл"
    TMP_FILES="${TMP_FILES}${tmp_file}
"
    REPLY=$tmp_file
}

acquire_manager_lock() (
    mkdir -p "$RUN_DIR" || exit 1
    [ ! -L "$RUN_DIR" ] || exit 1
    mkdir "$RUN_DIR/manager-recovery.lock" 2>/dev/null || exit 1
    trap 'rmdir "$RUN_DIR/manager-recovery.lock" 2>/dev/null || true' EXIT
    if [ -d "$RUN_DIR/manager.lock" ]; then
        manager_pid=$(cat "$RUN_DIR/manager.lock/pid" 2>/dev/null || true)
        is_positive_integer "$manager_pid" || exit 1
        kill -0 "$manager_pid" 2>/dev/null && exit 1
        rm -f "$RUN_DIR/manager.lock/pid" || exit 1
        rmdir "$RUN_DIR/manager.lock" || exit 1
    fi
    mkdir "$RUN_DIR/manager.lock" 2>/dev/null || exit 1
    printf '%s\n' "$$" > "$RUN_DIR/manager.lock/pid"
)

check_managed_directories() {
    for managed_dir in "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR"; do
        [ ! -L "$managed_dir" ] || die "каталог-ссылка не поддерживается: $managed_dir"
        [ -e "$managed_dir" ] || continue
        [ -d "$managed_dir" ] || die "ожидался каталог: $managed_dir"
        # BusyBox builds may omit stat -c. Read only the fixed metadata fields;
        # directory names (including spaces) are never split or interpreted.
        managed_listing=$(LC_ALL=C ls -ldn "$managed_dir" 2>/dev/null) || \
            die "не удалось прочитать права и владельца $managed_dir"
        managed_meta=$(printf '%s\n' "$managed_listing" | awk '
            NR == 1 && $1 ~ /^d[rwxstST-]+[.+@]?$/ && length($1) >= 10 &&
            $3 ~ /^[0-9]+$/ { print substr($1, 1, 10) ":" $3; exit }
        ')
        [ -n "$managed_meta" ] || die "не удалось распознать права и владельца $managed_dir"
        managed_owner=${managed_meta#*:}
        managed_mode=${managed_meta%%:*}
        [ "$managed_owner" = 0 ] || die "каталог должен принадлежать root: $managed_dir"
        case "$managed_mode" in
            ?????w????|????????w?) die "каталог доступен для записи другим пользователям: $managed_dir" ;;
        esac
    done
}

end_maintenance() {
    [ "$MAINTENANCE_HELD" = yes ] || return 0
    rmdir "$RUN_DIR/maintenance.lock" 2>/dev/null || true
    MAINTENANCE_HELD=no
}

begin_maintenance() {
    mkdir -p "$RUN_DIR" || die "не удалось подготовить каталог блокировок"
    mkdir "$RUN_DIR/maintenance.lock" 2>/dev/null || {
        warn "Уже выполняется обслуживание. Повторите позже."
        return 1
    }
    MAINTENANCE_HELD=yes
    wait_elapsed=0
    while :; do
        active_jobs=no
        for job_lock in "$RUN_DIR"/wg-watchdog-*.lock; do
            [ -d "$job_lock" ] || continue
            [ ! -L "$job_lock" ] || { active_jobs=yes; continue; }
            worker_pid=$(cat "$job_lock/pid" 2>/dev/null || true)
            if ! is_positive_integer "$worker_pid" || kill -0 "$worker_pid" 2>/dev/null; then
                active_jobs=yes
            else
                # New workers cannot enter while maintenance.lock exists.
                rm -f "$job_lock/pid" && rmdir "$job_lock" || active_jobs=yes
            fi
        done
        [ "$active_jobs" = yes ] || return 0
        if [ "$wait_elapsed" -ge "$WAIT_SECONDS" ]; then
            end_maintenance
            warn "Проверка ещё выполняется или блокировка не завершена. Изменения отменены."
            return 1
        fi
        [ "$wait_elapsed" -ne 0 ] || info "Ожидаю завершения работающих проверок (до $WAIT_SECONDS сек.)..."
        "$SLEEP_BIN" 1
        wait_elapsed=$((wait_elapsed + 1))
    done
}

remove_job_files() {
    valid_interface "$1" || return 1
    rm -f "$CONFIG_DIR/$1.conf" "$STATE_DIR/$1.state" "$RUN_DIR/wg-watchdog-$1.pid"
}

read_answer() {
    prompt=$1
    default_value=${2:-}
    if [ "$UI_ACTIVE" = yes ]; then
        ui_prompt "$prompt ${default_value:+[$default_value]}"
    elif [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value" >&4
    else
        printf '%s: ' "$prompt" >&4
    fi
    IFS= read -r answer <&3 || die "не удалось прочитать ответ"
    [ -n "$answer" ] || answer=$default_value
    REPLY=$answer
}

confirm() {
    if [ "$UI_ACTIVE" = yes ]; then ui_prompt "$1 [y/N]"; else printf '%s [y/N]: ' "$1" >&4; fi
    IFS= read -r answer <&3 || die "не удалось прочитать ответ"
    case "$answer" in
        д|Д|да|Да|ДА|y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_yes() {
    if [ "$UI_ACTIVE" = yes ]; then ui_prompt "$1 [Y/n]"; else printf '%s [Y/n]: ' "$1" >&4; fi
    IFS= read -r answer <&3 || die "не удалось прочитать ответ"
    case "$answer" in
        н|Н|нет|Нет|НЕТ|n|N|no|NO|No) return 1 ;;
        *) return 0 ;;
    esac
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0|0[0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_interface() {
    case "$1" in
        Wireguard*)
            suffix=${1#Wireguard}
            case "$suffix" in ''|*[!0-9]*) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    return 0
}

valid_address() {
    case "$1" in
        ''|*[!0-9A-Za-z.:-]*) return 1 ;;
        *[0-9A-Za-z]*) return 0 ;;
        *) return 1 ;;
    esac
}

NUMERIC_PARAMETERS="PING_COUNT PING_TIMEOUT RESTART_DELAY CHECK_INTERVAL FAILURE_THRESHOLD RESTART_COOLDOWN BOOT_GRACE RECOVERY_CHECK_DELAY"

parameter_spec() {
    SPEC_ALLOWED=""
    case "$1" in
        PING_COUNT) SPEC_DEFAULT=3; SPEC_MIN=1; SPEC_MAX=10; SPEC_DESCRIPTION="число ping-запросов при проверке" ;;
        PING_TIMEOUT) SPEC_DEFAULT=3; SPEC_MIN=1; SPEC_MAX=30; SPEC_DESCRIPTION="ожидание каждого ответа, секунд" ;;
        RESTART_DELAY) SPEC_DEFAULT=3; SPEC_MIN=1; SPEC_MAX=60; SPEC_DESCRIPTION="пауза down/up интерфейса, секунд" ;;
        CHECK_INTERVAL) SPEC_DEFAULT=5; SPEC_MIN=1; SPEC_MAX=60; SPEC_ALLOWED="1 2 3 4 5 6 10 12 15 20 30 60"; SPEC_DESCRIPTION="частота проверки в минутах" ;;
        FAILURE_THRESHOLD) SPEC_DEFAULT=2; SPEC_MIN=1; SPEC_MAX=10; SPEC_DESCRIPTION="неудачных проверок до перезапуска" ;;
        RESTART_COOLDOWN) SPEC_DEFAULT=30; SPEC_MIN=1; SPEC_MAX=1440; SPEC_DESCRIPTION="пауза между перезапусками, минут" ;;
        BOOT_GRACE) SPEC_DEFAULT=180; SPEC_MIN=1; SPEC_MAX=3600; SPEC_DESCRIPTION="ожидание после загрузки роутера, секунд" ;;
        RECOVERY_CHECK_DELAY) SPEC_DEFAULT=15; SPEC_MIN=1; SPEC_MAX=300; SPEC_DESCRIPTION="ожидание проверки после перезапуска, секунд" ;;
        *) return 1 ;;
    esac
}

get_parameter_value() {
    case "$1" in
        PING_COUNT) REPLY=$PING_COUNT ;;
        PING_TIMEOUT) REPLY=$PING_TIMEOUT ;;
        RESTART_DELAY) REPLY=$RESTART_DELAY ;;
        CHECK_INTERVAL) REPLY=$CHECK_INTERVAL ;;
        FAILURE_THRESHOLD) REPLY=$FAILURE_THRESHOLD ;;
        RESTART_COOLDOWN) REPLY=$RESTART_COOLDOWN ;;
        BOOT_GRACE) REPLY=$BOOT_GRACE ;;
        RECOVERY_CHECK_DELAY) REPLY=$RECOVERY_CHECK_DELAY ;;
        *) return 1 ;;
    esac
}

set_parameter_value() {
    case "$1" in
        PING_COUNT) PING_COUNT=$2 ;;
        PING_TIMEOUT) PING_TIMEOUT=$2 ;;
        RESTART_DELAY) RESTART_DELAY=$2 ;;
        CHECK_INTERVAL) CHECK_INTERVAL=$2 ;;
        FAILURE_THRESHOLD) FAILURE_THRESHOLD=$2 ;;
        RESTART_COOLDOWN) RESTART_COOLDOWN=$2 ;;
        BOOT_GRACE) BOOT_GRACE=$2 ;;
        RECOVERY_CHECK_DELAY) RECOVERY_CHECK_DELAY=$2 ;;
        *) return 1 ;;
    esac
}

valid_parameter_value() {
    parameter_spec "$1" || return 1
    is_positive_integer "$2" || return 1
    if [ -n "$SPEC_ALLOWED" ]; then
        case " $SPEC_ALLOWED " in *" $2 "*) return 0 ;; *) return 1 ;; esac
    fi
    [ "$2" -ge "$SPEC_MIN" ] && [ "$2" -le "$SPEC_MAX" ]
}

apply_default_parameters() {
    for parameter_name in $NUMERIC_PARAMETERS; do
        parameter_spec "$parameter_name" || return 1
        set_parameter_value "$parameter_name" "$SPEC_DEFAULT" || return 1
    done
}

normalize_parameters() {
    normalization_job=${1:-}
    for parameter_name in $NUMERIC_PARAMETERS; do
        get_parameter_value "$parameter_name" || return 1
        parameter_value=$REPLY
        if ! valid_parameter_value "$parameter_name" "$parameter_value"; then
            parameter_spec "$parameter_name" || return 1
            set_parameter_value "$parameter_name" "$SPEC_DEFAULT" || return 1
            if [ -n "$normalization_job" ]; then
                say "Параметр $parameter_name задания $normalization_job заменён на $SPEC_DEFAULT."
            fi
        fi
    done
}

ask_parameter() {
    parameter_name=$1
    current_value=$2
    parameter_spec "$parameter_name" || return 1
    if [ -n "$SPEC_ALLOWED" ]; then
        parameter_limits=$SPEC_ALLOWED
    else
        parameter_limits="$SPEC_MIN–$SPEC_MAX"
    fi
    while :; do
        read_answer "$parameter_name — $SPEC_DESCRIPTION ($parameter_limits)" "$current_value"
        if valid_parameter_value "$parameter_name" "$REPLY"; then
            set_parameter_value "$parameter_name" "$REPLY"
            return 0
        fi
        if [ -n "$SPEC_ALLOWED" ]; then
            say "Допустимые значения: $SPEC_ALLOWED."
        else
            say "Введите целое число от $SPEC_MIN до $SPEC_MAX без ведущих нулей."
        fi
    done
}

valid_interval() {
    valid_parameter_value CHECK_INTERVAL "$1"
}

cron_schedule() {
    case "$1" in
        1) REPLY='*' ;;
        60) REPLY='0' ;;
        *) REPLY="*/$1" ;;
    esac
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

version_is_newer() {
    awk -F. -v remote="$1" -v current="$2" 'BEGIN {
        split(remote, r, ".")
        split(current, c, ".")
        for (i = 1; i <= 3; i++) {
            if ((r[i] + 0) > (c[i] + 0)) exit 0
            if ((r[i] + 0) < (c[i] + 0)) exit 1
        }
        exit 1
    }'
}

fetch_remote_release() {
    make_temp release
    release_file=$REPLY
    if ! download_file "$RELEASE_MANIFEST_URL" "$release_file"; then
        return 1
    fi
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
    ' "$release_file") || return 1
    old_ifs=$IFS
    IFS="$(printf '\t')"
    set -- $release_values
    IFS=$old_ifs
    [ "$#" -eq 4 ] || return 1
    REMOTE_VERSION=$1
    REMOTE_COMMIT=$2
    REMOTE_WATCHDOG_SHA256=$3
    REMOTE_MANAGER_SHA256=$4
    return 0
}

check_update_status() {
    UPDATE_AVAILABLE=unknown
    REMOTE_VERSION=""
    REMOTE_COMMIT=""
    REMOTE_WATCHDOG_SHA256=""
    REMOTE_MANAGER_SHA256=""
    if fetch_remote_release; then
        if version_is_newer "$REMOTE_VERSION" "$VERSION"; then
            UPDATE_AVAILABLE=yes
        else
            UPDATE_AVAILABLE=no
        fi
    fi
}

ensure_short_command() {
    if [ -L "$SHORT_COMMAND" ] && [ "$(readlink "$SHORT_COMMAND" 2>/dev/null)" = "$MANAGER_PATH" ]; then
        return 0
    fi
    if [ -e "$SHORT_COMMAND" ] || [ -L "$SHORT_COMMAND" ]; then
        warn "$SHORT_COMMAND уже занят; используйте $MANAGER_PATH."
        return 0
    fi
    existing_command=$(command -v wgwm 2>/dev/null || true)
    if [ -n "$existing_command" ]; then
        warn "Команда wgwm уже занята ($existing_command); она не изменена."
        return 0
    fi
    ln -s "$MANAGER_PATH" "$SHORT_COMMAND" || die "не удалось создать команду wgwm"
}

ensure_environment() {
    [ -r "$INPUT_DEVICE" ] && [ -w "$OUTPUT_DEVICE" ] || \
        die "менеджер нужно запускать из интерактивного терминала"
    [ "$(id -u 2>/dev/null)" = "0" ] || die "запустите менеджер от пользователя root"
    [ -d "$OPT_ROOT" ] || die "каталог $OPT_ROOT отсутствует — сначала установите Entware"
    command -v opkg >/dev/null 2>&1 || die "команда opkg не найдена — Entware не запущен"
    mkdir -p "$OPT_ROOT/bin" "$OPT_ROOT/etc" "$TMP_DIR" "$RUN_DIR" "$CONFIG_DIR" "$STATE_DIR" || \
        die "не удалось создать рабочие каталоги"

    missing_packages=""
    command -v "$NDMC_BIN" >/dev/null 2>&1 || missing_packages="ndmq"
    [ -x "$CRON_INIT" ] || missing_packages="$missing_packages cron"
    if [ -n "$missing_packages" ]; then
        info "Устанавливаю необходимые пакеты:$missing_packages"
        run_visible opkg update || die "не удалось обновить список пакетов Entware"
        # Only fixed package names assembled above, never user input.
        run_visible opkg install $missing_packages || die "не удалось установить зависимости"
    fi

    if grep -q '^ENABLED=no' "$CRON_INIT" 2>/dev/null; then
        sed -i 's/^ENABLED=no/ENABLED=yes/' "$CRON_INIT" || \
            die "не удалось включить автозапуск cron"
    fi
}

valid_update_dir() {
    [ "$UPDATE_DIR" = "$OPT_ROOT/bin/.wg-watchdog-update" ]
}

clear_update_dir() {
    valid_update_dir || return 1
    [ ! -L "$UPDATE_DIR" ] || return 1
    rm -f "$UPDATE_DIR/watchdog.new" "$UPDATE_DIR/manager.new" \
        "$UPDATE_DIR/watchdog.old" "$UPDATE_DIR/manager.old" \
        "$UPDATE_DIR/watchdog.restore" "$UPDATE_DIR/manager.restore" \
        "$UPDATE_DIR/state" "$UPDATE_DIR/state.next" || return 1
    rmdir "$UPDATE_DIR" 2>/dev/null || return 1
}

write_update_state() {
    printf '%s\n' "$1" > "$UPDATE_DIR/state.next" || return 1
    chmod 600 "$UPDATE_DIR/state.next" || return 1
    mv "$UPDATE_DIR/state.next" "$UPDATE_DIR/state" || return 1
}

sync_update_storage() {
    "$SYNC_BIN" >/dev/null 2>&1
}

sha256_file() {
    digest=$("$SHA256_BIN" "$1" 2>/dev/null | awk 'NR == 1 { print $1; exit }') || return 1
    [ "${#digest}" -eq 64 ] || return 1
    case "$digest" in *[!0-9a-f]*) return 1 ;; esac
    REPLY=$digest
}

rollback_update() {
    valid_update_dir || return 1
    [ -f "$UPDATE_DIR/watchdog.old" ] && [ -f "$UPDATE_DIR/manager.old" ] || return 1
    cp "$UPDATE_DIR/watchdog.old" "$UPDATE_DIR/watchdog.restore" || return 1
    cp "$UPDATE_DIR/manager.old" "$UPDATE_DIR/manager.restore" || return 1
    chmod 755 "$UPDATE_DIR/watchdog.restore" "$UPDATE_DIR/manager.restore" || return 1
    sh -n "$UPDATE_DIR/watchdog.restore" && sh -n "$UPDATE_DIR/manager.restore" || return 1
    mv "$UPDATE_DIR/watchdog.restore" "$WATCHDOG_PATH" || return 1
    mv "$UPDATE_DIR/manager.restore" "$MANAGER_PATH" || return 1
    sync_update_storage || return 1
    if ! clear_update_dir; then
        warn "Служебные файлы обновления будут очищены при следующем запуске."
    fi
    return 0
}

recover_interrupted_update() {
    [ -e "$UPDATE_DIR" ] || return 0
    valid_update_dir || return 1
    [ -d "$UPDATE_DIR" ] && [ ! -L "$UPDATE_DIR" ] || return 1
    update_state=$(sed -n '1p' "$UPDATE_DIR/state" 2>/dev/null || true)
    case "$update_state" in
        committed)
            clear_update_dir || return 1
            info "Завершена очистка предыдущего обновления."
            ;;
        installing|watchdog-installed)
            begin_maintenance || return 1
            if rollback_update; then
                end_maintenance
                info "Восстановлена предыдущая версия после незавершённого обновления."
            else
                end_maintenance
                return 1
            fi
            ;;
        '')
            # Live files are not replaced before the first durable state marker.
            clear_update_dir || return 1
            ;;
        *) return 1 ;;
    esac
}

enough_space_for_update() {
    new_bytes=$(wc -c < "$1") || return 1
    new_manager_bytes=$(wc -c < "$2") || return 1
    old_bytes=$(wc -c < "$WATCHDOG_PATH") || return 1
    old_manager_bytes=$(wc -c < "$MANAGER_PATH") || return 1
    required_kb=$(((new_bytes + new_manager_bytes + old_bytes + old_manager_bytes + 1023) / 1024 + 64))
    available_kb=$("$DF_BIN" -Pk "$OPT_ROOT/bin" 2>/dev/null | awk '
        NR > 1 && $4 ~ /^[0-9]+$/ { available = $4 }
        END { if (available == "") exit 1; print available }
    ') || return 1
    is_positive_integer "$available_kb" || return 1
    [ "$available_kb" -ge "$required_kb" ]
}

transactional_install() {
    source_watchdog=$1
    source_manager=$2
    target_version=$3
    valid_update_dir || return 1
    [ -f "$WATCHDOG_PATH" ] && [ ! -L "$WATCHDOG_PATH" ] || return 1
    [ -f "$MANAGER_PATH" ] && [ ! -L "$MANAGER_PATH" ] || return 1
    [ ! -e "$UPDATE_DIR" ] || return 1
    enough_space_for_update "$source_watchdog" "$source_manager" || {
        say "Недостаточно свободного места для обновления и резервной копии."
        return 1
    }
    mkdir "$UPDATE_DIR" || return 1
    chmod 700 "$UPDATE_DIR" || { clear_update_dir >/dev/null 2>&1 || true; return 1; }
    if ! cp "$WATCHDOG_PATH" "$UPDATE_DIR/watchdog.old" || \
       ! cp "$MANAGER_PATH" "$UPDATE_DIR/manager.old" || \
       ! cp "$source_watchdog" "$UPDATE_DIR/watchdog.new" || \
       ! cp "$source_manager" "$UPDATE_DIR/manager.new" || \
       ! chmod 755 "$UPDATE_DIR"/*.old "$UPDATE_DIR"/*.new; then
        clear_update_dir >/dev/null 2>&1 || true
        return 1
    fi
    if ! sh -n "$UPDATE_DIR/watchdog.new" || ! sh -n "$UPDATE_DIR/manager.new" || \
       ! write_update_state installing || ! sync_update_storage; then
        clear_update_dir >/dev/null 2>&1 || true
        return 1
    fi
    if ! mv "$UPDATE_DIR/watchdog.new" "$WATCHDOG_PATH" || ! sync_update_storage || \
       ! write_update_state watchdog-installed || ! sync_update_storage || \
       ! mv "$UPDATE_DIR/manager.new" "$MANAGER_PATH" || ! sync_update_storage; then
        rollback_update || say "КРИТИЧЕСКАЯ ОШИБКА: автоматический откат не завершён."
        return 1
    fi
    installed_watchdog_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$WATCHDOG_PATH" | sed -n '1p')
    installed_manager_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$MANAGER_PATH" | sed -n '1p')
    if [ "$installed_watchdog_version" != "$target_version" ] || \
       [ "$installed_manager_version" != "$target_version" ] || \
       ! write_update_state committed || ! sync_update_storage; then
        rollback_update || say "КРИТИЧЕСКАЯ ОШИБКА: автоматический откат не завершён."
        return 1
    fi
    clear_update_dir
}

install_program_files() {
    make_temp watchdog
    tmp_watchdog=$REPLY
    make_temp manager
    tmp_manager=$REPLY

    target_version=${REMOTE_VERSION:-$VERSION}
    info "Загружаю файлы WG Watchdog Manager версии $target_version..."
    release_url="$RAW_REPOSITORY_URL/$REMOTE_COMMIT"
    download_file "$release_url/wg-watchdog.sh" "$tmp_watchdog" || {
        say "Ошибка обновления: не удалось загрузить watchdog."
        return 1
    }
    download_file "$release_url/wg-watchdog-manager.sh" "$tmp_manager" || {
        say "Ошибка обновления: не удалось загрузить менеджер."
        return 1
    }
    watchdog_size=$(wc -c < "$tmp_watchdog") || {
        say "Ошибка обновления: не удалось проверить размер watchdog."
        return 1
    }
    manager_size=$(wc -c < "$tmp_manager") || {
        say "Ошибка обновления: не удалось проверить размер менеджера."
        return 1
    }
    [ "$watchdog_size" -gt 0 ] && [ "$watchdog_size" -le 131072 ] || {
        say "Ошибка обновления: недопустимый размер watchdog."
        return 1
    }
    [ "$manager_size" -gt 0 ] && [ "$manager_size" -le 262144 ] || {
        say "Ошибка обновления: недопустимый размер менеджера."
        return 1
    }
    sh -n "$tmp_watchdog" || {
        say "Ошибка обновления: ошибка синтаксиса в загруженном watchdog."
        return 1
    }
    sh -n "$tmp_manager" || {
        say "Ошибка обновления: ошибка синтаксиса в загруженном менеджере."
        return 1
    }
    downloaded_watchdog_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp_watchdog" | sed -n '1p')
    downloaded_manager_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp_manager" | sed -n '1p')
    [ "$downloaded_watchdog_version" = "$target_version" ] || {
        say "Ошибка обновления: watchdog имеет версию ${downloaded_watchdog_version:-неизвестно}, ожидалась $target_version."
        return 1
    }
    [ "$downloaded_manager_version" = "$target_version" ] || {
        say "Ошибка обновления: менеджер имеет версию ${downloaded_manager_version:-неизвестно}, ожидалась $target_version."
        return 1
    }
    sha256_file "$tmp_watchdog" || {
        say "Ошибка обновления: не удалось вычислить SHA-256 watchdog."
        return 1
    }
    [ "$REPLY" = "$REMOTE_WATCHDOG_SHA256" ] || {
        say "Ошибка обновления: SHA-256 watchdog не совпадает с манифестом."
        return 1
    }
    sha256_file "$tmp_manager" || {
        say "Ошибка обновления: не удалось вычислить SHA-256 менеджера."
        return 1
    }
    [ "$REPLY" = "$REMOTE_MANAGER_SHA256" ] || {
        say "Ошибка обновления: SHA-256 менеджера не совпадает с манифестом."
        return 1
    }
    begin_maintenance || return 1
    update_result=0
    transactional_install "$tmp_watchdog" "$tmp_manager" "$target_version" || update_result=$?
    end_maintenance
    [ "$update_result" -eq 0 ] || return "$update_result"
    ensure_short_command
}

show_update_notice() {
    if [ "$UPDATE_AVAILABLE" = "yes" ]; then
        say ""
        say "${COLOR_YELLOW}ДОСТУПНА НОВАЯ ВЕРСИЯ: $VERSION → $REMOTE_VERSION${COLOR_RESET}"
        say "Выберите обновление в основном меню."
    elif [ "$UPDATE_AVAILABLE" = "unknown" ]; then
        warn "Обновления проверить не удалось; локальное управление доступно."
    fi
}

perform_update() {
    if [ "$UPDATE_AVAILABLE" = "yes" ]; then
        info "Перепроверяю наличие новой версии..."
    else
        info "Проверяю наличие новой версии..."
    fi
    check_update_status
    if [ "$UPDATE_AVAILABLE" = "unknown" ]; then
        result_card warning "Не удалось проверить обновления." \
            "Локальное управление продолжает работать." \
            "Проверьте доступ в интернет и повторите попытку."
        return 0
    fi
    if [ "$UPDATE_AVAILABLE" = "no" ]; then
        result_card success "Установлена актуальная версия $VERSION."
        return 0
    fi
    say "Доступна версия $REMOTE_VERSION; установлена версия $VERSION."
    confirm_yes "Загрузить и установить обновление?" || {
        result_card cancelled "Обновление не выполнялось."
        return 0
    }
    if ! install_program_files; then
        result_card error "Обновление не установлено." \
            "Предыдущая версия сохранена или восстановлена." \
            "Проверьте сообщения выше и повторите попытку."
        return 0
    fi
    info "Обновление установлено. Перезапускаю менеджер..."
    cleanup
    ui_stop
    release_manager_lock
    exec "$MANAGER_PATH" --after-update
    die "не удалось запустить обновлённый менеджер"
}

detect_interfaces() {
    RUNNING_CONFIG=$("$NDMC_BIN" -c "show running-config" 2>/dev/null || true)
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
}

interface_description() {
    result=$(printf '%s\n' "$INTERFACE_LIST" | awk -F '\t' -v wanted="$1" '
        $1 == wanted { print $2; found = 1; exit }
        END { if (!found) print "без описания" }
    ')
    REPLY=$result
}

interface_listen_port() {
    listen_interface=$1
    result=$(printf '%s\n' "$RUNNING_CONFIG" | awk -v wanted="$listen_interface" '
        $1 == "interface" {
            if (in_target) exit
            in_target = ($2 == wanted)
            next
        }
        in_target && $1 == "wireguard" && $2 == "listen-port" && \
            $3 ~ /^[0-9]+$/ && $3 > 0 && $3 <= 65535 {
            print $3
            exit
        }
    ')
    REPLY=$result
}

show_listen_port_warning() {
    interface_listen_port "$1"
    [ -n "$REPLY" ] || return 0
    FIXED_LISTEN_PORT=$REPLY
    warn "На $1 задан фиксированный локальный порт WireGuard: $FIXED_LISTEN_PORT."
    say "Для исходящего клиентского туннеля рекомендуется оставить «Порт прослушивания» пустым."
    say "Не путайте его с портом сервера в Endpoint — серверный порт удалять нельзя."
}

choose_interface() {
    current=${1:-}
    detect_interfaces

    if [ -n "$INTERFACE_LIST" ]; then
        say "Доступные WireGuard-интерфейсы:"
        index=1
        default_index=1
        while IFS="$(printf '\t')" read -r iface description; do
            say "  $index) $iface — $description"
            index=$((index + 1))
        done <<EOF
$INTERFACE_LIST
EOF
        if [ -n "$current" ]; then
            default_index=$(printf '%s\n' "$INTERFACE_LIST" | awk -F '\t' -v wanted="$current" '
                $1 == wanted { print NR; found = 1; exit }
                END { if (!found) print 1 }
            ')
        fi
        interface_count=$(printf '%s\n' "$INTERFACE_LIST" | awk 'NF { count++ } END { print count + 0 }')
        while :; do
            read_answer "Выберите номер интерфейса" "$default_index"
            if is_positive_integer "$REPLY" && [ "$REPLY" -le "$interface_count" ]; then
                WG_INTERFACE=$(printf '%s\n' "$INTERFACE_LIST" | sed -n "${REPLY}p" | cut -f1)
                return 0
            fi
            say "Введите номер от 1 до $interface_count."
        done
    fi

    say "Автоматически определить интерфейсы не удалось."
    read_answer "Введите системное имя WireGuard-интерфейса" "${current:-Wireguard0}"
    valid_interface "$REPLY" || die "недопустимое имя интерфейса: $REPLY"
    WG_INTERFACE=$REPLY
}

detect_peer_defaults() {
    selected_interface=$1
    PEER_LIST=$(printf '%s\n' "$RUNNING_CONFIG" | awk -v wanted="$selected_interface" '
        function endpoint_host(value, closing, count, parts) {
            if (substr(value, 1, 1) == "[") {
                closing = index(value, "]")
                if (closing > 2) return substr(value, 2, closing - 2)
            }
            count = split(value, parts, ":")
            if (count == 2) return parts[1]
            return value
        }
        function flush_peer() {
            if (!in_peer) return
            if (endpoint == "") endpoint = "-"
            if (tunnel_ip == "") tunnel_ip = "-"
            peer_label = substr(peer_key, 1, 8)
            print endpoint "\t" tunnel_ip "\t" peer_label
        }
        $1 == "interface" {
            if (in_target) {
                flush_peer()
                in_target = 0
                exit
            }
            in_target = ($2 == wanted)
            in_peer = 0
            next
        }
        in_target && $1 == "wireguard" && $2 == "peer" {
            flush_peer()
            in_peer = 1
            peer_key = $3
            endpoint = ""
            tunnel_ip = ""
            next
        }
        in_target && in_peer && $1 == "endpoint" {
            endpoint = endpoint_host($2)
            next
        }
        in_target && in_peer && $1 == "allow-ips" && tunnel_ip == "" {
            candidate = $2
            if (candidate ~ /\/32$/) {
                sub(/\/32$/, "", candidate)
                if (candidate != "0.0.0.0") tunnel_ip = candidate
            } else if ($3 == "255.255.255.255" && candidate != "0.0.0.0") {
                tunnel_ip = candidate
            }
        }
        END {
            if (in_target) flush_peer()
        }
    ')

    DETECTED_TUNNEL_IP=""
    DETECTED_PUBLIC_IP=""
    peer_count=$(printf '%s\n' "$PEER_LIST" | awk 'NF { count++ } END { print count + 0 }')
    [ "$peer_count" -gt 0 ] || return 0

    peer_index=1
    if [ "$peer_count" -gt 1 ]; then
        say "Найдено несколько пиров выбранного интерфейса:"
        while IFS="$(printf '\t')" read -r endpoint tunnel_ip peer_label; do
            [ "$endpoint" = "-" ] && endpoint="внешний адрес не найден"
            [ "$tunnel_ip" = "-" ] && tunnel_ip="внутренний адрес не найден"
            say "  $peer_index) peer $peer_label… — $endpoint; $tunnel_ip"
            peer_index=$((peer_index + 1))
        done <<EOF
$PEER_LIST
EOF
        while :; do
            read_answer "Выберите пир WG-сервера" "1"
            if is_positive_integer "$REPLY" && [ "$REPLY" -le "$peer_count" ]; then
                selected_peer=$REPLY
                break
            fi
            say "Введите номер от 1 до $peer_count."
        done
    else
        selected_peer=1
    fi

    selected_row=$(printf '%s\n' "$PEER_LIST" | sed -n "${selected_peer}p")
    DETECTED_PUBLIC_IP=$(printf '%s\n' "$selected_row" | cut -f1)
    DETECTED_TUNNEL_IP=$(printf '%s\n' "$selected_row" | cut -f2)
    [ "$DETECTED_PUBLIC_IP" = "-" ] && DETECTED_PUBLIC_IP=""
    [ "$DETECTED_TUNNEL_IP" = "-" ] && DETECTED_TUNNEL_IP=""
    return 0
}

reset_config_values() {
    JOB_ID=""
    WG_INTERFACE=""
    WG_SERVER_TUNNEL_IP=""
    PING_COUNT=""
    PING_TIMEOUT=""
    RESTART_DELAY=""
    CHECK_INTERVAL=""
    INTERNET_CHECK=""
    INTERNET_CHECK_TARGET_1=""
    INTERNET_CHECK_TARGET_2=""
    WG_SERVER_PUBLIC_IP=""
    FAILURE_THRESHOLD=""
    RESTART_COOLDOWN=""
    BOOT_GRACE=""
    RECOVERY_CHECK_DELAY=""
    ENABLED=""
}

load_config() {
    config_file=$1
    expected_job=${2:-}
    reset_config_values
    [ -r "$config_file" ] || return 1
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
    done < "$config_file"
    if [ -n "$expected_job" ] && {
        [ "$JOB_ID" != "$expected_job" ] || [ "$WG_INTERFACE" != "$expected_job" ];
    }; then
        return 1
    fi
    return 0
}

write_config() {
    destination="$CONFIG_DIR/$JOB_ID.conf"
    make_temp config
    tmp_config=$REPLY
    cat > "$tmp_config" <<EOF
# WG Watchdog — управляется через wgwm; формат конфигурации 1
JOB_ID='$JOB_ID'
WG_INTERFACE='$WG_INTERFACE'
WG_SERVER_TUNNEL_IP='$WG_SERVER_TUNNEL_IP'
WG_SERVER_PUBLIC_IP='$WG_SERVER_PUBLIC_IP'
PING_COUNT='$PING_COUNT'
PING_TIMEOUT='$PING_TIMEOUT'
RESTART_DELAY='$RESTART_DELAY'
CHECK_INTERVAL='$CHECK_INTERVAL'
INTERNET_CHECK='$INTERNET_CHECK'
INTERNET_CHECK_TARGET_1='$INTERNET_CHECK_TARGET_1'
INTERNET_CHECK_TARGET_2='$INTERNET_CHECK_TARGET_2'
FAILURE_THRESHOLD='$FAILURE_THRESHOLD'
RESTART_COOLDOWN='$RESTART_COOLDOWN'
BOOT_GRACE='$BOOT_GRACE'
RECOVERY_CHECK_DELAY='$RECOVERY_CHECK_DELAY'
ENABLED='$ENABLED'
EOF
    chmod 600 "$tmp_config" || die "не удалось установить права на конфигурацию"
    if [ -f "$destination" ] && cmp -s "$tmp_config" "$destination"; then
        rm -f "$tmp_config"
        return 0
    fi
    mv "$tmp_config" "$destination" || die "не удалось сохранить $destination"
}

ensure_cron_running() {
    if "$PIDOF_BIN" cron >/dev/null 2>&1; then
        return 0
    fi
    "$CRON_INIT" start >/dev/null 2>&1 || die "не удалось запустить cron"
    "$PIDOF_BIN" cron >/dev/null 2>&1 || die "процесс cron не запущен"
}

filter_managed_cron() {
    # Fail closed on malformed markers; never consume unrelated entries.
    awk -v begin="$CRON_BEGIN" -v end="$CRON_END" -v script="$WATCHDOG_PATH" '
        $0 == begin { if (managed || seen++) bad = 1; managed = 1; next }
        $0 == end { if (!managed) bad = 1; managed = 0; next }
        managed { next }
        $6 == "root" && ($7 == script || $7 == "/opt/bin/wg-watchdog.sh") { next }
        { print }
        END { if (managed || bad) exit 1 }
    ' "$CRONTAB_PATH"
}

# A subshell isolates configuration variables from the selected job.
rewrite_crontab() (
    TMP_FILES=""
    trap cleanup EXIT
    make_temp cron-clean
    clean_file=$REPLY
    make_temp cron-new
    new_file=$REPLY

    if [ -f "$CRONTAB_PATH" ]; then
        filter_managed_cron > "$clean_file" || die "повреждены границы блока WG Watchdog в crontab; файл не изменён"
    fi

    cat "$clean_file" > "$new_file" || die "не удалось подготовить crontab"
    printf '%s\n' "$CRON_BEGIN" >> "$new_file"
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        config_name=${config_file##*/}
        expected_job=${config_name%.conf}
        load_config "$config_file" "$expected_job" || {
            warn "Пропущен повреждённый файл ${config_file##*/}."
            continue
        }
        if [ "$ENABLED" = "yes" ] && valid_interface "$JOB_ID" && \
           valid_interval "$CHECK_INTERVAL"; then
            cron_schedule "$CHECK_INTERVAL"
            printf '%s * * * * root %s --job %s\n' \
                "$REPLY" "$WATCHDOG_PATH" "$JOB_ID" >> "$new_file"
        fi
    done
    printf '%s\n' "$CRON_END" >> "$new_file"
    chmod 600 "$new_file" || die "не удалось установить права на crontab"

    if [ -f "$CRONTAB_PATH" ] && cmp -s "$new_file" "$CRONTAB_PATH"; then
        rm -f "$new_file"
        ensure_cron_running
        return 0
    fi

    if [ -f "$CRONTAB_PATH" ]; then
        cp "$CRONTAB_PATH" "$CRONTAB_PATH.wg-watchdog.bak" 2>/dev/null || true
    fi
    mv "$new_file" "$CRONTAB_PATH" || die "не удалось сохранить crontab"

    "$CRON_INIT" restart >/dev/null 2>&1 || die "не удалось запустить cron"
    "$PIDOF_BIN" cron >/dev/null 2>&1 || die "процесс cron не запущен"
)

normalize_config_files() {
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        config_name=${config_file##*/}
        expected_job=${config_name%.conf}
        load_config "$config_file" "$expected_job" || {
            warn "Файл ${config_file##*/} повреждён и не изменён."
            continue
        }
        valid_interface "$JOB_ID" || continue
        [ "$WG_INTERFACE" = "$JOB_ID" ] || continue
        valid_address "$WG_SERVER_TUNNEL_IP" || continue
        normalize_parameters "$JOB_ID" || die "внутренняя ошибка схемы параметров"
        WG_SERVER_PUBLIC_IP=${WG_SERVER_PUBLIC_IP:-}
        case "${INTERNET_CHECK:-}" in yes|no) ;; *) INTERNET_CHECK=no ;; esac
        INTERNET_CHECK_TARGET_1=${INTERNET_CHECK_TARGET_1:-1.1.1.1}
        INTERNET_CHECK_TARGET_2=${INTERNET_CHECK_TARGET_2:-8.8.8.8}
        if ! valid_address "$INTERNET_CHECK_TARGET_1"; then
            INTERNET_CHECK_TARGET_1=1.1.1.1
            say "Контрольный адрес 1 задания $JOB_ID заменён на 1.1.1.1."
        fi
        if ! valid_address "$INTERNET_CHECK_TARGET_2"; then
            INTERNET_CHECK_TARGET_2=8.8.8.8
            say "Контрольный адрес 2 задания $JOB_ID заменён на 8.8.8.8."
        fi
        [ "$ENABLED" = "yes" ] || ENABLED=no
        write_config
    done
}

configure_job() {
    mode=$1
    original_job=${2:-}

    if [ "$mode" = "edit" ]; then
        load_config "$CONFIG_DIR/$original_job.conf" "$original_job" || {
            result_card error "Настройки $original_job повреждены; изменение отменено." \
                "Файл задания не соответствует безопасному формату."
            return 1
        }
        old_interface=$WG_INTERFACE
        default_server=$WG_SERVER_TUNNEL_IP
        default_internet_check=${INTERNET_CHECK:-yes}
        default_internet_target_1=${INTERNET_CHECK_TARGET_1:-1.1.1.1}
        default_internet_target_2=${INTERNET_CHECK_TARGET_2:-8.8.8.8}
        default_public_ip=${WG_SERVER_PUBLIC_IP:-}
        old_enabled=$ENABLED
    else
        old_interface=""
        default_server=""
        apply_default_parameters || die "внутренняя ошибка схемы параметров"
        default_internet_check=no
        default_internet_target_1=1.1.1.1
        default_internet_target_2=8.8.8.8
        default_public_ip=""
        old_enabled=yes
    fi

    if [ "$mode" = "edit" ]; then
        detect_interfaces
        WG_INTERFACE=$old_interface
        interface_description "$WG_INTERFACE"
        info "Редактируется задание для $WG_INTERFACE — $REPLY"
    elif [ -n "$original_job" ]; then
        detect_interfaces
        WG_INTERFACE=$original_job
        interface_description "$WG_INTERFACE"
        info "Настраивается задание для $WG_INTERFACE — $REPLY"
    else
        choose_interface ""
    fi
    JOB_ID=$WG_INTERFACE
    if [ -f "$CONFIG_DIR/$JOB_ID.conf" ] && \
       { [ "$mode" != edit ] || [ "$JOB_ID" != "$original_job" ]; }; then
        result_card warning "Для $JOB_ID уже существует задание." \
            "Новое задание не создано." \
            "Используйте пункт «Изменить задание»."
        return 1
    fi

    show_listen_port_warning "$WG_INTERFACE"

    if [ "$mode" = "add" ]; then
        detect_peer_defaults "$WG_INTERFACE"
    else
        DETECTED_TUNNEL_IP=""
        DETECTED_PUBLIC_IP=""
    fi
    if [ -z "$default_server" ] && [ -n "$DETECTED_TUNNEL_IP" ]; then
        default_server=$DETECTED_TUNNEL_IP
    fi
    if [ -n "$DETECTED_TUNNEL_IP" ]; then
        info "Внутренний адрес найден в Allowed IPs выбранного WireGuard-пира."
    fi
    if [ -n "$DETECTED_PUBLIC_IP" ]; then
        say "В Endpoint выбранного пира найден публичный адрес: $DETECTED_PUBLIC_IP"
    fi
    if [ "$mode" = "add" ] && [ -z "$DETECTED_TUNNEL_IP" ]; then
        say "Внутренний адрес сервера не удалось определить автоматически."
        say "Он отсутствует в конфигурации, если в Allowed IPs указана только сеть или 0.0.0.0/0."
        say "Введите адрес сервера внутри WireGuard-туннеля вручную."
        say ""
    fi

    while :; do
        read_answer "Введите внутренний IP-адрес WireGuard-сервера" "$default_server"
        if valid_address "$REPLY"; then
            WG_SERVER_TUNNEL_IP=$REPLY
            break
        fi
        say "Введите IP-адрес или имя хоста без пробелов."
    done

    info "Проверяю связь с $WG_SERVER_TUNNEL_IP..."
    if "$PING_BIN" -c 3 -W 3 "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
        say "Сервер отвечает на ping."
    else
        say "Сервер не ответил. Возможно, туннель сейчас не работает или ICMP запрещён."
        confirm "Продолжить настройку?" || {
            result_card cancelled "Настройка задания не сохранена."
            return 1
        }
    fi

    if [ "$UI_ACTIVE" = yes ]; then
        ui_clear
    else
        say ""
    fi
    say "Необязательная проверка публичного адреса помогает отличить отключённый"
    say "сервер от неисправного туннеля. Включайте её только если публичный адрес"
    say "стабильно отвечает на ping: иначе watchdog может пропустить восстановление."
    say ""

    use_public_probe=no
    suggested_public_ip=$DETECTED_PUBLIC_IP
    if [ -n "$default_public_ip" ]; then
        suggested_public_ip=$default_public_ip
        say "Сейчас используется публичный адрес: $default_public_ip"
        if confirm_yes "Продолжать проверять публичный адрес?"; then
            use_public_probe=yes
        fi
    elif confirm "Использовать проверку публичного адреса?"; then
        use_public_probe=yes
    fi

    WG_SERVER_PUBLIC_IP=""
    if [ "$use_public_probe" = "yes" ]; then
        while :; do
            read_answer "Публичный IP или DNS-имя WG-сервера" "$suggested_public_ip"
            if valid_address "$REPLY"; then
                WG_SERVER_PUBLIC_IP=$REPLY
                break
            fi
            say "Введите IP-адрес или имя хоста без пробелов."
        done

        info "Проверяю публичный адрес $WG_SERVER_PUBLIC_IP..."
        if "$PING_BIN" -c 1 -W 3 "$WG_SERVER_PUBLIC_IP" >/dev/null 2>&1; then
            say "Публичный адрес WG-сервера отвечает."
        else
            warn "Публичный адрес не ответил. Если ICMP на нём запрещён,"
            say "лучше оставить это поле пустым, иначе watchdog будет пропускать восстановление."
            confirm "Сохранить этот публичный адрес несмотря на отсутствие ответа?" || \
                WG_SERVER_PUBLIC_IP=""
        fi
    fi

    if [ "$mode" = "edit" ]; then
        say ""
        say "Проверка обычного интернета по двум контрольным адресам может запретить"
        say "восстановление, если эти адреса маршрутизируются через сам WireGuard."
        say "Для full-tunnel её следует оставить выключенной."
        if [ "$default_internet_check" = yes ]; then
            if confirm_yes "Продолжать проверять обычный интернет?"; then
                INTERNET_CHECK=yes
            else
                INTERNET_CHECK=no
            fi
        elif confirm "Включить проверку обычного интернета?"; then
            INTERNET_CHECK=yes
        else
            INTERNET_CHECK=no
        fi
    else
        INTERNET_CHECK=$default_internet_check
    fi

    INTERNET_CHECK_TARGET_1=$default_internet_target_1
    INTERNET_CHECK_TARGET_2=$default_internet_target_2
    if [ "$INTERNET_CHECK" = yes ]; then
        say ""
        say "Укажите два контрольных адреса обычного интернета."
        say "Можно использовать IP-адреса или DNS-имена; ответа одного из двух достаточно."
        while :; do
            read_answer "Контрольный адрес 1 (IP или DNS-имя)" "$default_internet_target_1"
            if valid_address "$REPLY"; then
                INTERNET_CHECK_TARGET_1=$REPLY
                break
            fi
            say "Введите IP-адрес или DNS-имя без пробелов."
        done
        while :; do
            read_answer "Контрольный адрес 2 (IP или DNS-имя)" "$default_internet_target_2"
            if valid_address "$REPLY"; then
                INTERNET_CHECK_TARGET_2=$REPLY
                break
            fi
            say "Введите IP-адрес или DNS-имя без пробелов."
        done
    fi

    if [ "$mode" = "edit" ]; then
        say "Нажмите Enter, чтобы принять значение в скобках."
        for parameter_name in $NUMERIC_PARAMETERS; do
            get_parameter_value "$parameter_name" || die "внутренняя ошибка схемы параметров"
            current_parameter_value=$REPLY
            ask_parameter "$parameter_name" "$current_parameter_value" || \
                die "внутренняя ошибка схемы параметров"
        done
    fi
    ENABLED=$old_enabled

    write_config
    saved_job=$JOB_ID
    saved_enabled=$ENABLED
    rewrite_crontab || die "настройки сохранены, но cron не обновлён"
    if [ "$saved_enabled" = "yes" ]; then
        saved_state="включено"
    else
        saved_state="выключено"
    fi
    result_card success "Задание $saved_job сохранено и $saved_state."
    if [ "$mode" = "add" ]; then
        say "Применены рекомендуемые параметры:"
        say "  проверка каждые $CHECK_INTERVAL мин.; $PING_COUNT ping по $PING_TIMEOUT сек.;"
        say "  перезапуск после $FAILURE_THRESHOLD неудачных проверок; пауза down/up $RESTART_DELAY сек.;"
        say "  контроль после перезапуска через $RECOVERY_CHECK_DELAY сек.; cooldown $RESTART_COOLDOWN мин.;"
        say "  ожидание после загрузки роутера $BOOT_GRACE сек."
        say "  проверка обычного интернета выключена (безопасно для full-tunnel)."
        say "Изменить эти значения можно через пункт «Изменить задание»."
    fi
}

toggle_job() {
    SELECTED_JOB=$1
    valid_interface "$SELECTED_JOB" || return 1
    config_file="$CONFIG_DIR/$SELECTED_JOB.conf"
    load_config "$config_file" "$SELECTED_JOB" || {
        result_card error "Настройки $SELECTED_JOB повреждены." \
            "Переключение задания не выполнялось."
        return 1
    }
    if [ "$ENABLED" = "yes" ]; then
        ENABLED=no
        action="выключено"
    else
        ENABLED=yes
        action="включено"
    fi
    write_config
    rewrite_crontab || die "не удалось обновить cron"
    result_card success "Задание $SELECTED_JOB $action."
}

delete_job() {
    SELECTED_JOB=$1
    valid_interface "$SELECTED_JOB" || return 1
    confirm "Удалить задание $SELECTED_JOB и его настройки?" || {
        result_card cancelled "Задание $SELECTED_JOB сохранено без изменений."
        return 0
    }
    begin_maintenance || return 0
    load_config "$CONFIG_DIR/$SELECTED_JOB.conf" "$SELECTED_JOB" || {
        end_maintenance
        result_card error "Настройки $SELECTED_JOB повреждены; удаление отменено." \
            "Файл задания оставлен без изменений."
        return 1
    }
    ENABLED=no
    write_config
    rewrite_crontab || die "задание отключено, но cron не обновлён"
    remove_job_files "$SELECTED_JOB" || die "удаление не завершено: часть файлов осталась"
    end_maintenance
    result_card success "Задание $SELECTED_JOB удалено."
}

show_job_status() {
    SELECTED_JOB=$1
    valid_interface "$SELECTED_JOB" || return 1
    load_config "$CONFIG_DIR/$SELECTED_JOB.conf" "$SELECTED_JOB" || {
        result_card error "Настройки $SELECTED_JOB повреждены." \
            "Подробный статус недоступен."
        return 1
    }
    state_file="$STATE_DIR/$SELECTED_JOB.state"
    CONSECUTIVE_FAILURES=0
    LAST_CHECK_TEXT="никогда"
    LAST_SUCCESS_TEXT="никогда"
    LAST_RESTART_TEXT="никогда"
    LAST_RESULT="ещё не проверялось"
    if [ -r "$state_file" ]; then
        # Файл создаётся watchdog с правами 600.
        # shellcheck disable=SC1090
        . "$state_file"
    fi
    if [ "$ENABLED" = "yes" ]; then state="включено"; else state="выключено"; fi
    detect_interfaces
    interface_listen_port "$WG_INTERFACE"
    status_listen_port=$REPLY
    say ""
    say "Статус $SELECTED_JOB:"
    say "  Состояние задания:        $state"
    say "  Внутренний адрес сервера: $WG_SERVER_TUNNEL_IP"
    say "  Публичный адрес сервера:  ${WG_SERVER_PUBLIC_IP:-не используется}"
    if [ -n "$status_listen_port" ]; then
        say "  Локальный порт WG:        $status_listen_port (фиксированный)"
    else
        say "  Локальный порт WG:        автоматический"
    fi
    say "  Частота проверки:         $CHECK_INTERVAL мин."
    if [ "$INTERNET_CHECK" = yes ]; then
        say "  Проверка интернета:       включена"
        say "  Контрольные адреса:       $INTERNET_CHECK_TARGET_1, $INTERNET_CHECK_TARGET_2"
    else
        say "  Проверка интернета:       выключена"
    fi
    say "  Последний результат:      $LAST_RESULT"
    say "  Последняя проверка:       $LAST_CHECK_TEXT"
    say "  Последний успех:          $LAST_SUCCESS_TEXT"
    say "  Последний перезапуск:     $LAST_RESTART_TEXT"
    say "  Ошибок подряд:            $CONSECUTIVE_FAILURES из $FAILURE_THRESHOLD"
    say "  Cooldown:                  $RESTART_COOLDOWN мин."
    if [ -n "$status_listen_port" ]; then
        warn "Для исходящего клиента фиксированный локальный порт может мешать восстановлению после обрыва."
    fi
}

run_job_now() {
    SELECTED_JOB=$1
    valid_interface "$SELECTED_JOB" || return 1
    say "Запускаю проверку $SELECTED_JOB..."
    run_visible "$WATCHDOG_PATH" --job "$SELECTED_JOB" --force
    result=$?
    if [ "$result" -eq 0 ]; then
        result_card success "Проверка $SELECTED_JOB завершена." \
            "Подробности перезапусков: $WATCHDOG_LOG_COMMAND"
    else
        result_card error "Проверка $SELECTED_JOB завершилась с кодом $result." \
            "Watchdog сообщил об ошибке выполнения." \
            "Посмотрите системный журнал: $WATCHDOG_LOG_COMMAND"
    fi
}

show_job_events() {
    SELECTED_JOB=$1
    valid_interface "$SELECTED_JOB" || return 1
    make_temp keenetic-log
    log_file=$REPLY
    if ! "$NDMC_BIN" -c "show log" > "$log_file" 2>&1; then
        result_card error "Не удалось получить системный журнал KeeneticOS." \
            "Команда ndmc завершилась с ошибкой."
        return 1
    fi
    say "Последние события $SELECTED_JOB:"
    log_lines=$(awk -v marker="[$SELECTED_JOB]" '
        index($0, "wg-watchdog") && index($0, marker) {
            count++
            lines[(count - 1) % 20] = $0
        }
        END {
            if (count == 0) exit
            first = count > 20 ? count - 19 : 1
            for (i = first; i <= count; i++) print lines[(i - 1) % 20]
        }
    ' "$log_file")
    if [ -n "$log_lines" ]; then
        while IFS= read -r log_line; do say "$log_line"; done <<EOF
$log_lines
EOF
    else
        say "  События этого задания в текущем системном журнале не найдены."
    fi
    say ""
    say "Показано не более 20 записей; отдельный файл журнала не создаётся."
}

force_restart_job() {
    SELECTED_JOB=$1
    valid_interface "$SELECTED_JOB" || return 1
    load_config "$CONFIG_DIR/$SELECTED_JOB.conf" "$SELECTED_JOB" || {
        result_card error "Настройки $SELECTED_JOB повреждены." \
            "Принудительный перезапуск не выполнялся."
        return 1
    }
    warn "Интерфейс $WG_INTERFACE будет выключен на $RESTART_DELAY сек."
    say "Если SSH подключён через этот туннель, соединение может временно прерваться."
    say "Проверки ping, порог ошибок и cooldown при этом действии не используются."
    confirm "Принудительно перезапустить $WG_INTERFACE?" || {
        result_card cancelled "Интерфейс $WG_INTERFACE не перезапускался."
        return 0
    }
    begin_maintenance || return 0
    MANAGER_RECOVERY_INTERFACE=$WG_INTERFACE
    MANAGER_INTERFACE_NEEDS_UP=yes
    if ! "$NDMC_BIN" -c "interface $WG_INTERFACE down" >/dev/null 2>&1; then
        MANAGER_INTERFACE_NEEDS_UP=no
        end_maintenance
        result_card error "Не удалось выключить $WG_INTERFACE."
        return 1
    fi
    "$SLEEP_BIN" "$RESTART_DELAY"
    if ! "$NDMC_BIN" -c "interface $WG_INTERFACE up" >/dev/null 2>&1; then
        "$NDMC_BIN" -c "interface $WG_INTERFACE up" >/dev/null 2>&1 || true
        MANAGER_INTERFACE_NEEDS_UP=no
        end_maintenance
        result_card error "Не удалось включить $WG_INTERFACE." \
            "Выполнена повторная попытка; проверьте интерфейс вручную."
        return 1
    fi
    MANAGER_INTERFACE_NEEDS_UP=no
    end_maintenance
    result_card success "Интерфейс $WG_INTERFACE перезапущен." \
        "Пауза между выключением и включением: $RESTART_DELAY сек."
}

remove_managed_cron() {
    [ -f "$CRONTAB_PATH" ] || return 0
    make_temp cron-uninstall
    clean_file=$REPLY
    filter_managed_cron > "$clean_file" || die "повреждены границы блока WG Watchdog в crontab; удаление отменено"
    if cmp -s "$clean_file" "$CRONTAB_PATH"; then
        rm -f "$clean_file"
        return 0
    fi
    chmod 600 "$clean_file" || die "не удалось установить права на crontab"
    cp "$CRONTAB_PATH" "$CRONTAB_PATH.wg-watchdog.bak" 2>/dev/null || true
    mv "$clean_file" "$CRONTAB_PATH" || die "не удалось сохранить crontab"
    if [ -x "$CRON_INIT" ]; then
        "$CRON_INIT" restart >/dev/null 2>&1 || \
            warn "Не удалось перезапустить cron."
    fi
}

uninstall_program() {
    check_managed_directories
    say ""
    say "Что удалить:"
    say "  1) Удалить программу, но сохранить настроенные задания"
    say "  2) Удалить программу вместе со всеми заданиями"
    say "  0) Вернуться в главное меню"
    while :; do
        read_answer "Выберите вариант удаления" "0"
        case "$REPLY" in
            1) uninstall_mode=keep ; break ;;
            2) uninstall_mode=all ; break ;;
            0) return 0 ;;
            *) say "Введите 1, 2 или 0." ;;
        esac
    done
    say ""
    say "Пакеты Entware cron и ndmq останутся: они могут использоваться другими программами."
    if [ "$uninstall_mode" = keep ]; then
        say "Конфигурации останутся в $CONFIG_DIR и будут подхвачены после переустановки."
        confirm "Удалить программу и сохранить задания?" || {
            result_card cancelled "WG Watchdog Manager и задания сохранены без изменений."
            return 0
        }
    else
        say "Настройки заданий и их состояние будут удалены без возможности восстановления."
        confirm "Удалить программу и все задания?" || {
            result_card cancelled "WG Watchdog Manager и задания сохранены без изменений."
            return 0
        }
    fi
    begin_maintenance || return 0
    remove_managed_cron
    : > "$RUN_DIR/uninstalled" || die "не удалось заблокировать отложенные запуски"
    if [ "$uninstall_mode" = all ]; then
        for file in "$CONFIG_DIR"/*.conf; do
            [ -f "$file" ] || continue
            remove_id=${file##*/}
            remove_id=${remove_id%.conf}
            valid_interface "$remove_id" || continue
            remove_job_files "$remove_id" || die "удаление не завершено: часть файлов осталась"
        done
        rmdir "$CONFIG_DIR" 2>/dev/null || true
    else
        for state_file in "$STATE_DIR"/*.state; do
            [ -f "$state_file" ] || continue
            state_id=${state_file##*/}
            state_id=${state_id%.state}
            valid_interface "$state_id" || continue
            rm -f "$state_file" || die "не удалось очистить состояние $state_id"
        done
    fi
    rmdir "$STATE_DIR" 2>/dev/null || true
    if [ "$RUN_DIR" != "$STATE_DIR" ]; then
        rmdir "$RUN_DIR" 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_PATH" || die "удаление не завершено: watchdog остался; менеджер сохранён"
    rm -f "$MANAGER_PATH" || die "удаление не завершено: менеджер остался"
    if [ -L "$SHORT_COMMAND" ] && [ "$(readlink "$SHORT_COMMAND" 2>/dev/null)" = "$MANAGER_PATH" ]; then
        rm -f "$SHORT_COMMAND" || die "программа удалена, но не удалось удалить ссылку wgwm"
    fi
    ui_stop
    if [ "$uninstall_mode" = keep ]; then
        say "WG Watchdog Manager удалён. Настроенные задания сохранены в $CONFIG_DIR."
        say "После переустановки они снова появятся в менеджере и cron."
    else
        say "WG Watchdog Manager и все его задания удалены."
    fi
    say "Сторонние задания cron сохранены."
    exit 0
}

show_header() {
    if [ "${1:-compact}" = main ]; then
        say "${COLOR_CYAN} __      __  ___ __  __${COLOR_RESET}"
        say "${COLOR_CYAN} \\ \\ /\\ / / / __|  \\/  |${COLOR_RESET}"
        say "${COLOR_CYAN}  \\ V  V / | (_ | |\\/| |${COLOR_RESET}"
        say "${COLOR_CYAN}   \\_/\\_/   \\___|_|  |_|${COLOR_RESET}"
        say "${COLOR_CYAN}      WATCHDOG MANAGER${COLOR_RESET}"
        say "Контроль WireGuard · Версия $VERSION · Автор: $AUTHOR"
    else
        say "${COLOR_CYAN}WG Watchdog Manager  /  $VERSION${COLOR_RESET}"
        say "Автор: $AUTHOR · Контроль WireGuard"
    fi
}

show_interface_index() {
    detect_interfaces
    make_temp interfaces
    INTERFACE_INDEX=$REPLY
    INTERFACE_COUNT=0
    say "WireGuard-интерфейсы:"
    while IFS="$(printf '\t')" read -r iface description; do
        [ -n "$iface" ] || continue
        INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
        printf '%s\n' "$iface" >> "$INTERFACE_INDEX"
        interface_color=$COLOR_GRAY
        interface_line="  $INTERFACE_COUNT) $iface — $description"
        interface_config="$CONFIG_DIR/$iface.conf"
        if [ -f "$interface_config" ]; then
            if ! load_config "$interface_config" "$iface"; then
                interface_color=$COLOR_RED
                interface_line="$interface_line · настройки повреждены"
                say "${interface_color}${interface_line}${COLOR_RESET}"
                continue
            fi
            if [ "$JOB_ID" = "$iface" ] && [ "$WG_INTERFACE" = "$iface" ]; then
                if [ "$ENABLED" = yes ]; then
                    interface_color=$COLOR_GREEN
                    interface_line="  $INTERFACE_COUNT) $iface — $description · включена"
                else
                    interface_color=$COLOR_RED
                    interface_line="  $INTERFACE_COUNT) $iface — $description · выключена"
                fi
            fi
        fi
        say "${interface_color}$interface_line${COLOR_RESET}"
    done <<EOF
$INTERFACE_LIST
EOF

    for interface_config in "$CONFIG_DIR"/*.conf; do
        [ -f "$interface_config" ] || continue
        iface=${interface_config##*/}
        iface=${iface%.conf}
        valid_interface "$iface" || continue
        grep -Fx "$iface" "$INTERFACE_INDEX" >/dev/null 2>&1 && continue
        INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
        printf '%s\n' "$iface" >> "$INTERFACE_INDEX"
        if load_config "$interface_config" "$iface" && \
           [ "$JOB_ID" = "$iface" ] && [ "$WG_INTERFACE" = "$iface" ]; then
            if [ "$ENABLED" = yes ]; then
                interface_color=$COLOR_YELLOW
                state="включена"
            else
                interface_color=$COLOR_RED
                state="выключена"
            fi
            say "${interface_color}  $INTERFACE_COUNT) $iface — интерфейс не найден · $state${COLOR_RESET}"
        else
            say "${COLOR_RED}  $INTERFACE_COUNT) $iface — интерфейс не найден · настройки повреждены${COLOR_RESET}"
        fi
    done

    if [ "$INTERFACE_COUNT" -eq 0 ]; then
        say "  Не найдены. Интерфейс можно указать вручную."
    fi
}

show_update_menu_item() {
    if [ "$UPDATE_AVAILABLE" = "yes" ]; then
        say "${COLOR_GREEN}  $1) Обновить программу до версии $REMOTE_VERSION${COLOR_RESET}"
    else
        say "  $1) Проверить обновления"
    fi
}

interface_menu() {
    selected_interface=$1
    while :; do
        cleanup
        if [ "$UI_ACTIVE" = yes ]; then ui_clear; fi
        show_header
        detect_interfaces
        interface_description "$selected_interface"
        selected_description=$REPLY
        say ""
        say "Интерфейс: $selected_interface — $selected_description"
        selected_config="$CONFIG_DIR/$selected_interface.conf"
        configured=no
        damaged=no
        if [ -f "$selected_config" ]; then
            if load_config "$selected_config" "$selected_interface" && \
               [ "$JOB_ID" = "$selected_interface" ] && \
               [ "$WG_INTERFACE" = "$selected_interface" ]; then
                configured=yes
                if [ "$ENABLED" = yes ]; then
                    say "Watchdog: ${COLOR_GREEN}включён${COLOR_RESET} · сервер $WG_SERVER_TUNNEL_IP · каждые $CHECK_INTERVAL мин."
                    toggle_label="Выключить watchdog"
                else
                    say "Watchdog: ${COLOR_RED}выключен${COLOR_RESET} · сервер $WG_SERVER_TUNNEL_IP · каждые $CHECK_INTERVAL мин."
                    toggle_label="Включить watchdog"
                fi
            else
                damaged=yes
                say "Watchdog: ${COLOR_RED}настройки повреждены${COLOR_RESET}"
            fi
        else
            say "Watchdog: ${COLOR_GRAY}не настроен${COLOR_RESET}"
        fi
        say ""
        say "Действия:"
        if [ "$configured" = yes ]; then
            say "  1) Запустить проверку сейчас"
            say "  2) Показать подробный статус"
            say "  3) Показать последние события"
            say "  4) $toggle_label"
            say "  5) Изменить настройки"
            say "  6) Принудительно перезапустить интерфейс"
            say "  7) Удалить задание watchdog"
        elif [ "$damaged" = yes ]; then
            say "  1) Удалить повреждённое задание watchdog"
        else
            say "  1) Настроить watchdog"
        fi
        say "  0) Назад"
        read_answer "Выберите действие" "0"
        interface_action=$REPLY
        [ "$interface_action" = 0 ] && return 0
        if [ "$UI_ACTIVE" = yes ]; then
            ui_clear
            show_header
            say ""
            say "Интерфейс: $selected_interface — $selected_description"
            say ""
        fi
        ACTION_PAUSE=yes
        if [ "$configured" = yes ]; then
            case "$interface_action" in
                1) run_job_now "$selected_interface" ;;
                2) show_job_status "$selected_interface" ;;
                3) show_job_events "$selected_interface" ;;
                4) toggle_job "$selected_interface" ;;
                5) configure_job edit "$selected_interface" ;;
                6) force_restart_job "$selected_interface" ;;
                7) delete_job "$selected_interface" ;;
                *) say "Неизвестный пункт меню." ;;
            esac
        elif [ "$damaged" = yes ]; then
            case "$interface_action" in
                1)
                    confirm "Удалить повреждённое задание $selected_interface?" && {
                        rm -f "$selected_config" || die "не удалось удалить повреждённое задание"
                        rewrite_crontab || die "задание удалено, но cron не обновлён"
                        result_card success "Повреждённое задание $selected_interface удалено."
                    }
                    ;;
                *) say "Неизвестный пункт меню." ;;
            esac
        else
            case "$interface_action" in
                1) configure_job add "$selected_interface" ;;
                *) say "Неизвестный пункт меню." ;;
            esac
        fi
        [ "$ACTION_PAUSE" = yes ] && ui_pause
    done
}

main_menu() {
    while :; do
        cleanup
        if [ "$UI_ACTIVE" = yes ]; then ui_clear; fi
        show_header main
        if [ "$UPDATE_AVAILABLE" = yes ]; then
            say "${COLOR_YELLOW}Доступно обновление: $REMOTE_VERSION${COLOR_RESET}"
        fi
        say ""
        show_interface_index
        say ""
        say "Общие действия:"
        if [ "$INTERFACE_COUNT" -eq 0 ]; then
            manual_action=1
            update_action=2
            uninstall_action=3
            say "  $manual_action) Настроить интерфейс вручную"
        else
            manual_action=0
            update_action=$((INTERFACE_COUNT + 1))
            uninstall_action=$((INTERFACE_COUNT + 2))
        fi
        show_update_menu_item "$update_action"
        say "  $uninstall_action) Удалить WG Watchdog Manager"
        say "  0) Выход"
        read_answer "Выберите интерфейс или действие" "0"
        menu_action=$REPLY
        [ "$menu_action" = 0 ] && return 0
        ACTION_PAUSE=yes
        if is_positive_integer "$menu_action" && [ "$menu_action" -le "$INTERFACE_COUNT" ]; then
            selected_interface=$(sed -n "${menu_action}p" "$INTERFACE_INDEX")
            interface_menu "$selected_interface"
            ACTION_PAUSE=no
        elif [ "$manual_action" -ne 0 ] && [ "$menu_action" = "$manual_action" ]; then
            configure_job add ""
        elif [ "$menu_action" = "$update_action" ]; then
            perform_update
        elif [ "$menu_action" = "$uninstall_action" ]; then
            uninstall_program
        else
            say "Неизвестный пункт меню."
        fi
        [ "$ACTION_PAUSE" = yes ] && ui_pause
    done
}

if [ "${WG_WATCHDOG_LIB_ONLY:-no}" = "yes" ]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    --from-installer|--after-update) ;;
    --uninstall) ;;
    --repair) ;;
    --plain) ;;
    '') ;;
    *) die "неизвестный параметр: $1" ;;
esac
[ "$#" -le 1 ] || die "ожидался один параметр"

[ -r "$INPUT_DEVICE" ] && [ -w "$OUTPUT_DEVICE" ] || \
    die "менеджер нужно запускать из интерактивного терминала"
open_console
if [ "${1:-}" != --plain ]; then ui_start; fi
[ "$(id -u)" = 0 ] || die "требуются права root"
check_managed_directories
acquire_manager_lock || die "менеджер уже запущен или его блокировка не завершена; закройте другую сессию"
MANAGER_LOCK_HELD=yes
recover_interrupted_update || die "не удалось восстановить незавершённое обновление; запустите установщик с --force"
if [ "${1:-}" = --uninstall ]; then
    uninstall_program
    exit 0
fi
if [ "${1:-}" = --repair ]; then
    command -v "$SHA256_BIN" >/dev/null 2>&1 || die "команда sha256sum не найдена"
    command -v "$DF_BIN" >/dev/null 2>&1 || die "команда df не найдена"
    command -v "$SYNC_BIN" >/dev/null 2>&1 || die "команда sync не найдена"
    fetch_remote_release || die "не удалось загрузить корректный манифест выпуска"
    install_program_files || die "не удалось восстановить программные файлы"
    say "WG Watchdog Manager $REMOTE_VERSION установлен с проверкой и возможностью отката."
    exit 0
fi
rm -f "$RUN_DIR/uninstalled"
ensure_environment
normalize_config_files
ensure_short_command
rewrite_crontab || exit 1

check_update_status
show_update_notice
main_menu
say "Выход из WG Watchdog Manager."
exit 0
