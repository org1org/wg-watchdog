#!/bin/sh

# Interactive job manager for WG Watchdog.

VERSION="1.3.0"
AUTHOR="org1org"
BASE_URL="https://raw.githubusercontent.com/org1org/wg-watchdog/main"
WATCHDOG_URL="$BASE_URL/wg-watchdog.sh"
MANAGER_URL="$BASE_URL/wg-watchdog-manager.sh"
VERSION_URL="$BASE_URL/VERSION"
WATCHDOG_PATH="/opt/bin/wg-watchdog.sh"
MANAGER_PATH="/opt/bin/wg-watchdog-manager"
SHORT_COMMAND="/opt/bin/wgwm"
CONFIG_DIR="/opt/etc/wg-watchdog.d"
STATE_DIR="/tmp/wg-watchdog"
RUN_DIR="/tmp/wg-watchdog"
TMP_DIR="/tmp"
LEGACY_CONFIG="/opt/etc/wg-watchdog.conf"
CRONTAB_PATH="/opt/etc/crontab"
CRON_INIT="/opt/etc/init.d/S10cron"
NDMC_BIN="ndmc"
PING_BIN="ping"
PIDOF_BIN="pidof"
CRON_BEGIN="# BEGIN WG-WATCHDOG — managed automatically"
CRON_END="# END WG-WATCHDOG"
TTY_DEVICE="${WG_WATCHDOG_TTY:-/dev/tty}"
INPUT_DEVICE="${WG_WATCHDOG_INPUT:-$TTY_DEVICE}"
OUTPUT_DEVICE="${WG_WATCHDOG_OUTPUT:-$TTY_DEVICE}"
PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

TMP_FILES=""
CONSOLE_OPEN=no

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_GREEN=$(printf '\033[1;32m')
    COLOR_YELLOW=$(printf '\033[1;33m')
    COLOR_CYAN=$(printf '\033[1;36m')
    COLOR_RESET=$(printf '\033[0m')
else
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_RESET=""
fi

UPDATE_AVAILABLE=unknown
REMOTE_VERSION=""

cleanup() {
    for file in $TMP_FILES; do
        rm -f "$file"
    done
}
trap cleanup EXIT HUP INT TERM

say() { printf '%s\n' "$*"; }
info() { printf '\n%s%s%s\n\n' "$COLOR_GREEN" "$*" "$COLOR_RESET"; }
die() { say "Ошибка: $*" >&2; exit 1; }

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
    tmp_file="$TMP_DIR/wg-watchdog.$$.$1"
    TMP_FILES="$TMP_FILES $tmp_file"
    : > "$tmp_file" || die "не удалось создать временный файл $tmp_file"
    REPLY=$tmp_file
}

read_answer() {
    prompt=$1
    default_value=${2:-}
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value" >&4
    else
        printf '%s: ' "$prompt" >&4
    fi
    IFS= read -r answer <&3 || die "не удалось прочитать ответ"
    [ -n "$answer" ] || answer=$default_value
    REPLY=$answer
}

confirm() {
    printf '%s [y/N]: ' "$1" >&4
    IFS= read -r answer <&3 || die "не удалось прочитать ответ"
    case "$answer" in
        д|Д|да|Да|ДА|y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_yes() {
    printf '%s [Y/n]: ' "$1" >&4
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
        wget -q -O "$2" "$1" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2" && return 0
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

fetch_remote_version() {
    make_temp version
    version_file=$REPLY
    if ! download_file "$VERSION_URL" "$version_file"; then
        return 1
    fi
    remote=$(sed -n '1{s/[[:space:]]//g;p;}' "$version_file")
    case "$remote" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) return 1 ;;
    esac
    if ! printf '%s\n' "$remote" | awk '
        /^[0-9]+\.[0-9]+\.[0-9]+$/ { ok = 1 }
        END { exit ok ? 0 : 1 }
    '; then
        return 1
    fi
    REMOTE_VERSION=$remote
    return 0
}

check_update_status() {
    UPDATE_AVAILABLE=unknown
    REMOTE_VERSION=""
    if fetch_remote_version; then
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
    [ -d /opt ] || die "каталог /opt отсутствует — сначала установите Entware"
    command -v opkg >/dev/null 2>&1 || die "команда opkg не найдена — Entware не запущен"
    mkdir -p /opt/bin /opt/etc "$TMP_DIR" "$RUN_DIR" "$CONFIG_DIR" "$STATE_DIR" || \
        die "не удалось создать рабочие каталоги"

    if ! command -v "$NDMC_BIN" >/dev/null 2>&1; then
        info "Устанавливаю ndmq для управления KeeneticOS..."
        opkg update || die "не удалось обновить список пакетов Entware"
        opkg install ndmq || die "не удалось установить ndmq"
        say ""
    fi

    if [ ! -x "$CRON_INIT" ]; then
        info "Устанавливаю cron..."
        opkg update || die "не удалось обновить список пакетов Entware"
        opkg install cron || die "не удалось установить cron"
        say ""
    fi

    if grep -q '^ENABLED=no' "$CRON_INIT" 2>/dev/null; then
        sed -i 's/^ENABLED=no/ENABLED=yes/' "$CRON_INIT" || \
            die "не удалось включить автозапуск cron"
    fi
}

install_program_files() {
    make_temp watchdog
    tmp_watchdog=$REPLY
    make_temp manager
    tmp_manager=$REPLY

    info "Проверяю файлы WG Watchdog версии $VERSION..."
    download_file "$WATCHDOG_URL" "$tmp_watchdog" || die "не удалось загрузить watchdog"
    download_file "$MANAGER_URL" "$tmp_manager" || die "не удалось загрузить менеджер"
    sh -n "$tmp_watchdog" || die "ошибка синтаксиса в загруженном watchdog"
    sh -n "$tmp_manager" || die "ошибка синтаксиса в загруженном менеджере"
    chmod 755 "$tmp_watchdog" "$tmp_manager" || die "не удалось установить права"
    if [ -f "$WATCHDOG_PATH" ] && cmp -s "$tmp_watchdog" "$WATCHDOG_PATH"; then
        rm -f "$tmp_watchdog"
    else
        mv "$tmp_watchdog" "$WATCHDOG_PATH" || die "не удалось установить watchdog"
    fi
    if [ -f "$MANAGER_PATH" ] && cmp -s "$tmp_manager" "$MANAGER_PATH"; then
        rm -f "$tmp_manager"
    else
        mv "$tmp_manager" "$MANAGER_PATH" || die "не удалось установить менеджер"
    fi
    ensure_short_command
}

show_update_notice() {
    if [ "$UPDATE_AVAILABLE" = "yes" ]; then
        say ""
        printf '%s%s\n' "$COLOR_YELLOW" '=============================================='
        printf '  ДОСТУПНА НОВАЯ ВЕРСИЯ: %s → %s\n' "$VERSION" "$REMOTE_VERSION"
        printf '%s%s\n\n' '  Выберите обновление в основном меню.' "$COLOR_RESET"
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
    install_program_files
    info "Обновление установлено. Перезапускаю менеджер..."
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
        printf '%s\n' "$INTERFACE_LIST" | while IFS="$(printf '\t')" read -r iface description; do
            printf '  %s) %s — %s\n' "$index" "$iface" "$description"
            index=$((index + 1))
        done
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
        printf '%s\n' "$PEER_LIST" | while IFS="$(printf '\t')" read -r endpoint tunnel_ip peer_label; do
            [ "$endpoint" = "-" ] && endpoint="внешний адрес не найден"
            [ "$tunnel_ip" = "-" ] && tunnel_ip="внутренний адрес не найден"
            printf '  %s) peer %s… — %s; %s\n' \
                "$peer_index" "$peer_label" "$endpoint" "$tunnel_ip"
            peer_index=$((peer_index + 1))
        done
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
# WG Watchdog $VERSION — управляется через wg-watchdog-manager
JOB_ID='$JOB_ID'
WG_INTERFACE='$WG_INTERFACE'
WG_SERVER_TUNNEL_IP='$WG_SERVER_TUNNEL_IP'
WG_SERVER_PUBLIC_IP='$WG_SERVER_PUBLIC_IP'
PING_COUNT='$PING_COUNT'
PING_TIMEOUT='$PING_TIMEOUT'
RESTART_DELAY='$RESTART_DELAY'
CHECK_INTERVAL='$CHECK_INTERVAL'
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

rewrite_crontab() {
    make_temp cron-clean
    clean_file=$REPLY
    make_temp cron-new
    new_file=$REPLY

    if [ -f "$CRONTAB_PATH" ]; then
        awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
            $0 == begin { managed = 1; next }
            $0 == end { managed = 0; next }
            managed { next }
            /\/opt\/bin\/wg-watchdog\.sh/ { next }
            { print }
        ' "$CRONTAB_PATH" > "$clean_file" || die "не удалось прочитать crontab"
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
}

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

    detect_peer_defaults "$WG_INTERFACE"
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

    say "Нажмите Enter, чтобы принять значение в скобках."
    ask_integer_range PING_COUNT "PING_COUNT — число ping-запросов при проверке" "$default_ping_count" 1 10
    ask_integer_range PING_TIMEOUT "PING_TIMEOUT — ожидание каждого ответа, секунд" "$default_ping_timeout" 1 30
    ask_integer_range RESTART_DELAY "RESTART_DELAY — пауза down/up интерфейса, секунд" "$default_restart_delay" 1 60
    ask_interval "$default_interval"
    ask_integer_range FAILURE_THRESHOLD "FAILURE_THRESHOLD — неудачных проверок до перезапуска" "$default_failure_threshold" 1 10
    ask_integer_range RESTART_COOLDOWN "RESTART_COOLDOWN — пауза между перезапусками, минут" "$default_restart_cooldown" 1 1440
    ask_integer_range BOOT_GRACE "BOOT_GRACE — ожидание после загрузки роутера, секунд" "$default_boot_grace" 1 3600
    ask_integer_range RECOVERY_CHECK_DELAY "RECOVERY_CHECK_DELAY — ожидание проверки после перезапуска, секунд" "$default_recovery_delay" 1 300
    ENABLED=$old_enabled

    if [ -n "$original_job" ] && [ "$original_job" != "$JOB_ID" ]; then
        rm -f "$CONFIG_DIR/$original_job.conf" "$STATE_DIR/$original_job.state" \
            "$RUN_DIR/wg-watchdog-$original_job.pid"
    fi
    write_config
    saved_job=$JOB_ID
    saved_enabled=$ENABLED
    rewrite_crontab
    if [ "$saved_enabled" = "yes" ]; then
        saved_state="включено"
    else
        saved_state="выключено"
    fi
    info "Задание $saved_job сохранено и $saved_state."
}

build_job_index() {
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
        if [ "$ENABLED" = "yes" ]; then state="включено"; else state="выключено"; fi
        printf '  %s%s. %s — %s; сервер %s; каждые %s мин.; %s%s\n' \
            "$COLOR_GREEN" "$count" "$WG_INTERFACE" "$description" \
            "$WG_SERVER_TUNNEL_IP" "$CHECK_INTERVAL" "$state" "$COLOR_RESET"
    done
    JOB_COUNT=$count
}

select_job() {
    [ "$JOB_COUNT" -gt 0 ] || return 1
    while :; do
        read_answer "$1" "1"
        if is_positive_integer "$REPLY" && [ "$REPLY" -le "$JOB_COUNT" ]; then
            SELECTED_JOB=$(sed -n "${REPLY}p" "$JOB_INDEX")
            return 0
        fi
        say "Введите номер от 1 до $JOB_COUNT."
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
    rewrite_crontab
    say "Задание $SELECTED_JOB $action."
}

delete_job() {
    select_job "Какое задание удалить" || return
    confirm "Удалить задание $SELECTED_JOB и его настройки?" || return
    rm -f "$CONFIG_DIR/$SELECTED_JOB.conf" "$STATE_DIR/$SELECTED_JOB.state" \
        "$RUN_DIR/wg-watchdog-$SELECTED_JOB.pid"
    rm -f "$RUN_DIR/wg-watchdog-$SELECTED_JOB.lock/pid"
    rmdir "$RUN_DIR/wg-watchdog-$SELECTED_JOB.lock" 2>/dev/null || true
    rewrite_crontab
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
    "$WATCHDOG_PATH" --job "$SELECTED_JOB" --force
    result=$?
    if [ "$result" -eq 0 ]; then
        say "Проверка завершена. Подробности перезапусков: logread | grep wg-watchdog"
    else
        say "Проверка завершилась с кодом $result. Посмотрите системный журнал."
    fi
}

show_header() {
    say ""
    printf '%s%s%s\n' "$COLOR_CYAN" 'WG Watchdog Manager' "$COLOR_RESET"
    say "Контролирует доступность WG-сервера и автоматически перезапускает"
    say "зависшие WireGuard-интерфейсы. Поддерживает отдельное задание для каждого интерфейса."
    say "Автор: $AUTHOR    Версия: $VERSION"
    say ""
}

show_detected_interfaces() {
    detect_interfaces
    say "Найденные WireGuard-интерфейсы:"
    if [ -z "$INTERFACE_LIST" ]; then
        say "  Не найдены. При добавлении задания имя можно будет ввести вручную."
        return 0
    fi
    printf '%s\n' "$INTERFACE_LIST" | while IFS="$(printf '\t')" read -r iface description; do
        printf '  • %s — %s\n' "$iface" "$description"
    done
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
        say ""
        say "Настроенные задания:"
        build_job_index
        [ "$JOB_COUNT" -gt 0 ] || say "  Нет настроенных заданий."
        say ""
        if [ "$JOB_COUNT" -eq 0 ]; then
            say "  1) Добавить задание"
            show_update_menu_item 2
            say "  0) Выход"
        else
            say "  1) Добавить задание"
            say "  2) Изменить задание"
            say "  3) Включить/выключить задание"
            say "  4) Запустить проверку сейчас"
            say "  5) Показать подробный статус"
            say "  6) Удалить задание"
            show_update_menu_item 7
            say "  0) Выход"
        fi
        read_answer "Выберите действие" "0"
        if [ "$JOB_COUNT" -eq 0 ]; then
            case "$REPLY" in
                1) configure_job add "" ;;
                2) perform_update ;;
                0) return 0 ;;
                *) say "Неизвестный пункт меню." ;;
            esac
            continue
        fi
        case "$REPLY" in
            1) configure_job add "" ;;
            2)
                if [ "$JOB_COUNT" -eq 0 ]; then say "Нет заданий для изменения."
                elif select_job "Какое задание изменить"; then configure_job edit "$SELECTED_JOB"; fi
                ;;
            3) [ "$JOB_COUNT" -gt 0 ] && toggle_job || say "Нет настроенных заданий." ;;
            4) [ "$JOB_COUNT" -gt 0 ] && run_job_now || say "Нет настроенных заданий." ;;
            5) [ "$JOB_COUNT" -gt 0 ] && show_job_status || say "Нет настроенных заданий." ;;
            6) [ "$JOB_COUNT" -gt 0 ] && delete_job || say "Нет настроенных заданий." ;;
            7) perform_update ;;
            0) return 0 ;;
            *) say "Неизвестный пункт меню." ;;
        esac
    done
}

if [ "${WG_WATCHDOG_LIB_ONLY:-no}" = "yes" ]; then
    return 0 2>/dev/null || exit 0
fi

SKIP_CONFIRM=no
case "${1:-}" in
    --from-installer|--after-update) SKIP_CONFIRM=yes ;;
    '') ;;
    *) die "неизвестный параметр: $1" ;;
esac

[ -r "$INPUT_DEVICE" ] && [ -w "$OUTPUT_DEVICE" ] || \
    die "менеджер нужно запускать из интерактивного терминала"
open_console
show_header
if [ "$SKIP_CONFIRM" != "yes" ] && ! confirm_yes "Продолжить?"; then
    say "Настройка отменена."
    exit 0
fi
ensure_environment
cleanup_legacy_state
migrate_legacy_config
upgrade_config_files
ensure_short_command
rewrite_crontab

check_update_status
show_update_notice
show_detected_interfaces

main_menu
say "Настройки сохранены. Для управления запустите: wgwm"
exit 0
