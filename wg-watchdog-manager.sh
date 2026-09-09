#!/bin/sh

# Interactive job manager for WG Watchdog.

VERSION="1.7.0"
AUTHOR="org1org"
BASE_URL="https://raw.githubusercontent.com/org1org/wg-watchdog/main"
RAW_REPOSITORY_URL="${WG_WATCHDOG_RAW_REPOSITORY_URL:-https://raw.githubusercontent.com/org1org/wg-watchdog}"
WATCHDOG_URL="$BASE_URL/wg-watchdog.sh"
MANAGER_URL="$BASE_URL/wg-watchdog-manager.sh"
VERSION_URL="$BASE_URL/VERSION"
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
LEGACY_CONFIG="$OPT_ROOT/etc/wg-watchdog.conf"
CRONTAB_PATH="$OPT_ROOT/etc/crontab"
CRON_INIT="$OPT_ROOT/etc/init.d/S10cron"
NDMC_BIN="${WG_WATCHDOG_NDMC:-ndmc}"
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
        say "Уже выполняется обслуживание. Повторите позже."
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
            say "Проверка ещё выполняется или блокировка не завершена. Изменения отменены."
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
        ''|*[!0-9]*|0) return 1 ;;
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
        *) return 0 ;;
    esac
}

ask_integer_range() {
    variable_name=$1
    prompt=$2
    default_value=$3
    minimum=$4
    maximum=$5
    while :; do
        read_answer "$prompt ($minimum–$maximum)" "$default_value"
        if is_positive_integer "$REPLY" && [ "$REPLY" -ge "$minimum" ] && \
           [ "$REPLY" -le "$maximum" ]; then
            eval "$variable_name=\$REPLY"
            return 0
        fi
        say "Введите целое число от $minimum до $maximum."
    done
}

ask_interval() {
    while :; do
        read_answer "CHECK_INTERVAL — частота проверки в минутах (1,2,3,4,5,6,10,12,15,20,30,60)" "$1"
        if valid_interval "$REPLY"; then
            CHECK_INTERVAL=$REPLY
            return 0
        fi
        say "Допустимые значения: 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30 или 60."
    done
}

valid_interval() {
    case "$1" in
        1|2|3|4|5|6|10|12|15|20|30|60) return 0 ;;
        *) return 1 ;;
    esac
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
        say "Предупреждение: $SHORT_COMMAND уже занят; используйте $MANAGER_PATH."
        return 0
    fi
    existing_command=$(command -v wgwm 2>/dev/null || true)
    if [ -n "$existing_command" ]; then
        say "Предупреждение: команда wgwm уже занята ($existing_command); она не изменена."
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
        say "Предупреждение: служебные файлы обновления будут очищены при следующем запуске."
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
    info "Загружаю файлы WG Watchdog версии $target_version..."
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
        say "Обновления проверить не удалось; локальное управление доступно."
    fi
}

perform_update() {
    info "Проверяю наличие новой версии..."
    check_update_status
    if [ "$UPDATE_AVAILABLE" = "unknown" ]; then
        say "Не удалось получить сведения об обновлениях. Проверьте доступ в интернет."
        return 0
    fi
    if [ "$UPDATE_AVAILABLE" = "no" ]; then
        info "Установлена актуальная версия $VERSION."
        return 0
    fi
    say "Доступна версия $REMOTE_VERSION; установлена версия $VERSION."
    confirm "Загрузить и установить обновление?" || return 0
    if ! install_program_files; then
        say "Обновление не установлено; предыдущая версия сохранена или восстановлена."
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

load_config() {
    config_file=$1
    JOB_ID=""
    WG_INTERFACE=""
    WG_SERVER_TUNNEL_IP=""
    PING_COUNT=""
    PING_TIMEOUT=""
    RESTART_DELAY=""
    CHECK_INTERVAL=""
    INTERNET_CHECK=""
    WG_SERVER_PUBLIC_IP=""
    FAILURE_THRESHOLD=""
    RESTART_COOLDOWN=""
    BOOT_GRACE=""
    RECOVERY_CHECK_DELAY=""
    ENABLED=""
    # shellcheck disable=SC1090
    . "$config_file"
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
        load_config "$config_file"
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

cleanup_legacy_state() {
    legacy_state_dir="/opt/var/lib/wg-watchdog"
    [ -d "$legacy_state_dir" ] || return 0
    removed=no
    for state_file in "$legacy_state_dir"/*.state; do
        [ -f "$state_file" ] || continue
        rm -f "$state_file"
        removed=yes
    done
    rmdir "$legacy_state_dir" 2>/dev/null || true
    if [ "$removed" = "yes" ]; then
        say "Старые файлы состояния удалены из /opt: теперь состояние хранится в RAM."
    fi
}

migrate_legacy_config() {
    [ -f "$LEGACY_CONFIG" ] || return 0
    existing_count=$(find "$CONFIG_DIR" -type f -name '*.conf' 2>/dev/null | wc -l)
    [ "$existing_count" -eq 0 ] || return 0

    WG_INTERFACE=""
    WG_SERVER_TUNNEL_IP=""
    PING_COUNT="3"
    PING_TIMEOUT="3"
    RESTART_DELAY="3"
    # shellcheck disable=SC1090
    . "$LEGACY_CONFIG"
    is_positive_integer "$PING_COUNT" || PING_COUNT=3
    is_positive_integer "$PING_TIMEOUT" || PING_TIMEOUT=3
    is_positive_integer "$RESTART_DELAY" || RESTART_DELAY=3
    if valid_interface "$WG_INTERFACE" && valid_address "$WG_SERVER_TUNNEL_IP"; then
        JOB_ID=$WG_INTERFACE
        CHECK_INTERVAL=5
        INTERNET_CHECK=yes
        WG_SERVER_PUBLIC_IP=""
        FAILURE_THRESHOLD=2
        RESTART_COOLDOWN=30
        BOOT_GRACE=180
        RECOVERY_CHECK_DELAY=15
        ENABLED=yes
        write_config
        mv "$LEGACY_CONFIG" "$LEGACY_CONFIG.migrated-v1.0.0"
        say "Конфигурация v1.0.0 перенесена в актуальный формат."
    else
        say "Предупреждение: старую конфигурацию не удалось перенести автоматически."
    fi
}

upgrade_config_files() {
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        load_config "$config_file"
        valid_interface "$JOB_ID" || continue
        [ "$WG_INTERFACE" = "$JOB_ID" ] || continue
        valid_address "$WG_SERVER_TUNNEL_IP" || continue
        is_positive_integer "$PING_COUNT" && [ "$PING_COUNT" -le 10 ] || PING_COUNT=3
        is_positive_integer "$PING_TIMEOUT" && [ "$PING_TIMEOUT" -le 30 ] || PING_TIMEOUT=3
        is_positive_integer "$RESTART_DELAY" && [ "$RESTART_DELAY" -le 60 ] || RESTART_DELAY=3
        if ! valid_interval "$CHECK_INTERVAL"; then
            say "Интервал задания $JOB_ID заменён на точные 5 минут."
            CHECK_INTERVAL=5
        fi
        FAILURE_THRESHOLD=${FAILURE_THRESHOLD:-2}
        RESTART_COOLDOWN=${RESTART_COOLDOWN:-30}
        BOOT_GRACE=${BOOT_GRACE:-180}
        RECOVERY_CHECK_DELAY=${RECOVERY_CHECK_DELAY:-15}
        WG_SERVER_PUBLIC_IP=${WG_SERVER_PUBLIC_IP:-}
        # Jobs created before v1.7.0 keep their former external-network gate.
        case "${INTERNET_CHECK:-}" in yes|no) ;; *) INTERNET_CHECK=yes ;; esac
        is_positive_integer "$FAILURE_THRESHOLD" && [ "$FAILURE_THRESHOLD" -le 10 ] || FAILURE_THRESHOLD=2
        is_positive_integer "$RESTART_COOLDOWN" && [ "$RESTART_COOLDOWN" -le 1440 ] || RESTART_COOLDOWN=30
        is_positive_integer "$BOOT_GRACE" && [ "$BOOT_GRACE" -le 3600 ] || BOOT_GRACE=180
        is_positive_integer "$RECOVERY_CHECK_DELAY" && [ "$RECOVERY_CHECK_DELAY" -le 300 ] || RECOVERY_CHECK_DELAY=15
        [ "$ENABLED" = "yes" ] || ENABLED=no
        write_config
    done
}

configure_job() {
    mode=$1
    original_job=${2:-}

    if [ "$mode" = "edit" ]; then
        load_config "$CONFIG_DIR/$original_job.conf"
        old_interface=$WG_INTERFACE
        default_server=$WG_SERVER_TUNNEL_IP
        default_ping_count=$PING_COUNT
        default_ping_timeout=$PING_TIMEOUT
        default_restart_delay=$RESTART_DELAY
        default_interval=$CHECK_INTERVAL
        default_internet_check=${INTERNET_CHECK:-yes}
        default_public_ip=${WG_SERVER_PUBLIC_IP:-}
        default_failure_threshold=${FAILURE_THRESHOLD:-2}
        default_restart_cooldown=${RESTART_COOLDOWN:-30}
        default_boot_grace=${BOOT_GRACE:-180}
        default_recovery_delay=${RECOVERY_CHECK_DELAY:-15}
        old_enabled=$ENABLED
    else
        old_interface=""
        default_server=""
        default_ping_count=3
        default_ping_timeout=3
        default_restart_delay=3
        default_interval=5
        default_internet_check=no
        default_public_ip=""
        default_failure_threshold=2
        default_restart_cooldown=30
        default_boot_grace=180
        default_recovery_delay=15
        old_enabled=yes
    fi

    if [ "$mode" = "edit" ]; then
        detect_interfaces
        WG_INTERFACE=$old_interface
        interface_description "$WG_INTERFACE"
        info "Редактируется задание для $WG_INTERFACE — $REPLY"
    else
        choose_interface ""
    fi
    JOB_ID=$WG_INTERFACE
    if [ -f "$CONFIG_DIR/$JOB_ID.conf" ] && [ "$JOB_ID" != "$original_job" ]; then
        say "Для $JOB_ID уже существует задание. Используйте пункт «Изменить»."
        return 1
    fi

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
        confirm "Продолжить настройку?" || return 1
    fi

    say ""
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
            say "Предупреждение: публичный адрес не ответил. Если ICMP на нём запрещён,"
            say "лучше оставить это поле пустым, иначе watchdog будет пропускать восстановление."
            confirm "Сохранить этот публичный адрес несмотря на отсутствие ответа?" || \
                WG_SERVER_PUBLIC_IP=""
        fi
    fi

    if [ "$mode" = "edit" ]; then
        say ""
        say "Проверка обычного интернета по 1.1.1.1 и 8.8.8.8 может запретить"
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

    if [ "$mode" = "add" ]; then
        PING_COUNT=$default_ping_count
        PING_TIMEOUT=$default_ping_timeout
        RESTART_DELAY=$default_restart_delay
        CHECK_INTERVAL=$default_interval
        FAILURE_THRESHOLD=$default_failure_threshold
        RESTART_COOLDOWN=$default_restart_cooldown
        BOOT_GRACE=$default_boot_grace
        RECOVERY_CHECK_DELAY=$default_recovery_delay
    else
        say "Нажмите Enter, чтобы принять значение в скобках."
        ask_integer_range PING_COUNT "PING_COUNT — число ping-запросов при проверке" "$default_ping_count" 1 10
        ask_integer_range PING_TIMEOUT "PING_TIMEOUT — ожидание каждого ответа, секунд" "$default_ping_timeout" 1 30
        ask_integer_range RESTART_DELAY "RESTART_DELAY — пауза down/up интерфейса, секунд" "$default_restart_delay" 1 60
        ask_interval "$default_interval"
        ask_integer_range FAILURE_THRESHOLD "FAILURE_THRESHOLD — неудачных проверок до перезапуска" "$default_failure_threshold" 1 10
        ask_integer_range RESTART_COOLDOWN "RESTART_COOLDOWN — пауза между перезапусками, минут" "$default_restart_cooldown" 1 1440
        ask_integer_range BOOT_GRACE "BOOT_GRACE — ожидание после загрузки роутера, секунд" "$default_boot_grace" 1 3600
        ask_integer_range RECOVERY_CHECK_DELAY "RECOVERY_CHECK_DELAY — ожидание проверки после перезапуска, секунд" "$default_recovery_delay" 1 300
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
    info "Задание $saved_job сохранено и $saved_state."
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

build_job_index() {
    display_mode=${1:-page}
    detect_interfaces
    make_temp jobs
    JOB_INDEX=$REPLY
    count=0
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        load_config "$config_file"
        valid_interface "$JOB_ID" || continue
        count=$((count + 1))
        printf '%s\n' "$JOB_ID" >> "$JOB_INDEX"
        interface_description "$WG_INTERFACE"
        description=$REPLY
        if [ "$ENABLED" = "yes" ]; then
            state="включено"
            state_color=$COLOR_GREEN
        else
            state="выключено"
            state_color=$COLOR_RED
        fi
        if [ "$display_mode" = quiet ]; then
            :
        elif [ "$UI_ACTIVE" = yes ]; then
            say "$state_color$count. $WG_INTERFACE — $state$COLOR_RESET"
        else
            printf '  %s%s. %s — %s; сервер %s; каждые %s мин.; %s%s\n' \
                "$state_color" "$count" "$WG_INTERFACE" "$description" \
                "$WG_SERVER_TUNNEL_IP" "$CHECK_INTERVAL" "$state" "$COLOR_RESET"
        fi
    done
    JOB_COUNT=$count
}

select_job() {
    say "Настроенные задания:"
    build_job_index all
    [ "$JOB_COUNT" -gt 0 ] || { say "  Нет настроенных заданий."; return 1; }
    say ""
    say "  0) Вернуться в главное меню"
    while :; do
        read_answer "$1" ""
        if [ "$REPLY" = 0 ]; then
            ACTION_PAUSE=no
            SELECTED_JOB=""
            return 1
        fi
        if is_positive_integer "$REPLY" && [ "$REPLY" -le "$JOB_COUNT" ]; then
            SELECTED_JOB=$(sed -n "${REPLY}p" "$JOB_INDEX")
            return 0
        fi
        say "Введите номер от 1 до $JOB_COUNT или 0 для возврата."
    done
}

toggle_job() {
    select_job "Выберите задание" || return
    config_file="$CONFIG_DIR/$SELECTED_JOB.conf"
    load_config "$config_file"
    if [ "$ENABLED" = "yes" ]; then
        ENABLED=no
        action="выключено"
    else
        ENABLED=yes
        action="включено"
    fi
    write_config
    rewrite_crontab || die "не удалось обновить cron"
    say "Задание $SELECTED_JOB $action."
}

delete_job() {
    select_job "Какое задание удалить" || return
    confirm "Удалить задание $SELECTED_JOB и его настройки?" || return 0
    begin_maintenance || return 0
    load_config "$CONFIG_DIR/$SELECTED_JOB.conf"
    ENABLED=no
    write_config
    rewrite_crontab || die "задание отключено, но cron не обновлён"
    remove_job_files "$SELECTED_JOB" || die "удаление не завершено: часть файлов осталась"
    end_maintenance
    say "Задание $SELECTED_JOB удалено."
}

show_job_status() {
    select_job "Какое задание показать" || return
    load_config "$CONFIG_DIR/$SELECTED_JOB.conf"
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
    say ""
    say "Статус $SELECTED_JOB:"
    say "  Состояние задания:        $state"
    say "  Внутренний адрес сервера: $WG_SERVER_TUNNEL_IP"
    say "  Публичный адрес сервера:  ${WG_SERVER_PUBLIC_IP:-не используется}"
    say "  Частота проверки:         $CHECK_INTERVAL мин."
    if [ "$INTERNET_CHECK" = yes ]; then
        say "  Проверка интернета:       включена"
    else
        say "  Проверка интернета:       выключена"
    fi
    say "  Последний результат:      $LAST_RESULT"
    say "  Последняя проверка:       $LAST_CHECK_TEXT"
    say "  Последний успех:          $LAST_SUCCESS_TEXT"
    say "  Последний перезапуск:     $LAST_RESTART_TEXT"
    say "  Ошибок подряд:            $CONSECUTIVE_FAILURES из $FAILURE_THRESHOLD"
    say "  Cooldown:                  $RESTART_COOLDOWN мин."
}

run_job_now() {
    select_job "Какое задание проверить сейчас" || return
    say "Запускаю проверку $SELECTED_JOB..."
    run_visible "$WATCHDOG_PATH" --job "$SELECTED_JOB" --force
    result=$?
    if [ "$result" -eq 0 ]; then
        say "Проверка завершена. Подробности перезапусков: logread | grep wg-watchdog"
    else
        say "Проверка завершилась с кодом $result. Посмотрите системный журнал."
    fi
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
            say "Предупреждение: не удалось перезапустить cron."
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
        confirm "Удалить программу и сохранить задания?" || return 0
    else
        say "Настройки заданий и их состояние будут удалены без возможности восстановления."
        confirm "Удалить программу и все задания?" || return 0
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
        rm -f "$LEGACY_CONFIG" || die "не удалось удалить прежнюю конфигурацию"
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
        say "WG Watchdog удалён. Настроенные задания сохранены в $CONFIG_DIR."
        say "После переустановки они снова появятся в менеджере и cron."
    else
        say "WG Watchdog и все его задания удалены."
    fi
    say "Сторонние задания cron сохранены."
    exit 0
}

show_header() {
    if [ "$UI_ACTIVE" = yes ]; then
        say "${COLOR_CYAN}WG WATCHDOG  /  $VERSION${COLOR_RESET}"
        say "Автор: $AUTHOR · Контроль WireGuard"
        return 0
    fi
    say ""
    printf '%s%s%s\n' "$COLOR_CYAN" 'WG Watchdog Manager' "$COLOR_RESET"
    say "Контролирует доступность WG-сервера и автоматически перезапускает"
    say "зависшие WireGuard-интерфейсы. Поддерживает отдельное задание для каждого интерфейса."
    say "Автор: $AUTHOR    Версия: $VERSION"
    say ""
}

show_detected_interfaces() {
    detect_interfaces
    say "WireGuard-интерфейсы:"
    if [ -z "$INTERFACE_LIST" ]; then
        say "  Не найдены. При добавлении задания имя можно будет ввести вручную."
        return 0
    fi
    while IFS="$(printf '\t')" read -r iface description; do
        interface_color=$COLOR_GRAY
        interface_line="  $iface — $description"
        interface_config="$CONFIG_DIR/$iface.conf"
        if [ -f "$interface_config" ]; then
            load_config "$interface_config"
            if [ "$JOB_ID" = "$iface" ] && [ "$WG_INTERFACE" = "$iface" ]; then
                if [ "$ENABLED" = yes ]; then
                    interface_color=$COLOR_GREEN
                    interface_line="  $iface — включена · $description"
                else
                    interface_color=$COLOR_RED
                    interface_line="  $iface — выключена · $description"
                fi
            fi
        fi
        say "${interface_color}$interface_line${COLOR_RESET}"
    done <<EOF
$INTERFACE_LIST
EOF
}

show_update_menu_item() {
    if [ "$UPDATE_AVAILABLE" = "yes" ]; then
        say "  $1) Обновить программу до версии $REMOTE_VERSION"
    else
        say "  $1) Проверить обновления"
    fi
}

main_menu() {
    while :; do
        cleanup
        if [ "$UI_ACTIVE" = yes ]; then
            ui_clear
            show_header
            if [ "$UPDATE_AVAILABLE" = yes ]; then
                say "${COLOR_YELLOW}Доступно обновление: $REMOTE_VERSION${COLOR_RESET}"
            fi
            say ""
        fi
        build_job_index quiet
        show_detected_interfaces
        say ""
        say "Действия:"
        if [ "$JOB_COUNT" -eq 0 ]; then
            say "  1) Добавить задание"
            show_update_menu_item 2
            say "  3) Удалить WG Watchdog"
            say "  0) Выход"
        else
            say "  1) Добавить задание"
            say "  2) Изменить задание"
            say "  3) Включить/выключить задание"
            say "  4) Запустить проверку сейчас"
            say "  5) Показать подробный статус"
            say "  6) Удалить задание"
            show_update_menu_item 7
            say "  8) Удалить WG Watchdog"
            say "  0) Выход"
        fi
        read_answer "Выберите действие" "0"
        if [ "$REPLY" != 0 ] && [ "$UI_ACTIVE" = yes ]; then
            # Preserve the selected action while repainting the action screen.
            menu_action=$REPLY
            ui_clear
            show_header
            REPLY=$menu_action
        fi
        if [ "$JOB_COUNT" -eq 0 ]; then
            case "$REPLY" in
                1) configure_job add "" ;;
                2) perform_update ;;
                3) uninstall_program ;;
                0) return 0 ;;
                *) say "Неизвестный пункт меню." ;;
            esac
            ui_pause
            continue
        fi
        ACTION_PAUSE=yes
        case "$REPLY" in
            1) configure_job add "" ;;
            2)
                if select_job "Какое задание изменить"; then configure_job edit "$SELECTED_JOB"; fi
                ;;
            3) toggle_job ;;
            4) run_job_now ;;
            5) show_job_status ;;
            6) delete_job ;;
            7) perform_update ;;
            8) uninstall_program ;;
            0) return 0 ;;
            *) say "Неизвестный пункт меню." ;;
        esac
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
    say "WG Watchdog $REMOTE_VERSION установлен с проверкой и возможностью отката."
    exit 0
fi
rm -f "$RUN_DIR/uninstalled"
show_header
ensure_environment
cleanup_legacy_state
migrate_legacy_config
upgrade_config_files
ensure_short_command
rewrite_crontab || exit 1

check_update_status
show_update_notice
main_menu
say "Выход из WG Watchdog."
exit 0
