#!/bin/sh

# Interactive installer and job manager for WG Watchdog.

VERSION="1.1.0"
BASE_URL="https://raw.githubusercontent.com/org1org/wg-watchdog/main"
WATCHDOG_URL="$BASE_URL/wg-watchdog.sh"
MANAGER_URL="$BASE_URL/install.sh"
WATCHDOG_PATH="/opt/bin/wg-watchdog.sh"
MANAGER_PATH="/opt/bin/wg-watchdog-manager"
CONFIG_DIR="/opt/etc/wg-watchdog.d"
LEGACY_CONFIG="/opt/etc/wg-watchdog.conf"
CRONTAB_PATH="/opt/etc/crontab"
CRON_BEGIN="# BEGIN WG-WATCHDOG — managed automatically"
CRON_END="# END WG-WATCHDOG"
TTY_DEVICE="${WG_WATCHDOG_TTY:-/dev/tty}"
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
    tmp_file="/opt/tmp/wg-watchdog.$$.$1"
    TMP_FILES="$TMP_FILES $tmp_file"
    : > "$tmp_file" || die "не удалось создать временный файл $tmp_file"
    REPLY=$tmp_file
}

read_answer() {
    prompt=$1
    default_value=${2:-}
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value" > "$TTY_DEVICE"
    else
        printf '%s: ' "$prompt" > "$TTY_DEVICE"
    fi
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

ask_interval() {
    while :; do
        read_answer "CHECK_INTERVAL — частота проверки в минутах (1–59)" "$1"
        if is_positive_integer "$REPLY" && [ "$REPLY" -le 59 ]; then
            CHECK_INTERVAL=$REPLY
            return 0
        fi
        say "Введите целое число от 1 до 59."
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

ensure_environment() {
    [ -r "$TTY_DEVICE" ] || die "менеджер нужно запускать из интерактивного терминала"
    [ "$(id -u 2>/dev/null)" = "0" ] || die "запустите менеджер от пользователя root"
    [ -d /opt ] || die "каталог /opt отсутствует — сначала установите Entware"
    command -v opkg >/dev/null 2>&1 || die "команда opkg не найдена — Entware не запущен"
    mkdir -p /opt/bin /opt/etc /opt/tmp /opt/var/run "$CONFIG_DIR" || \
        die "не удалось создать рабочие каталоги"

    if ! command -v ndmc >/dev/null 2>&1; then
        say "Устанавливаю ndmq для управления KeeneticOS..."
        opkg update || die "не удалось обновить список пакетов Entware"
        opkg install ndmq || die "не удалось установить ndmq"
    fi

    if [ ! -x /opt/etc/init.d/S10cron ]; then
        say "Устанавливаю cron..."
        opkg update || die "не удалось обновить список пакетов Entware"
        opkg install cron || die "не удалось установить cron"
    fi

    if grep -q '^ENABLED=no' /opt/etc/init.d/S10cron 2>/dev/null; then
        sed -i 's/^ENABLED=no/ENABLED=yes/' /opt/etc/init.d/S10cron || \
            die "не удалось включить автозапуск cron"
    fi
}

install_program_files() {
    make_temp watchdog
    tmp_watchdog=$REPLY
    make_temp manager
    tmp_manager=$REPLY

    say "Обновляю файлы WG Watchdog до версии $VERSION..."
    download_file "$WATCHDOG_URL" "$tmp_watchdog" || die "не удалось загрузить watchdog"
    download_file "$MANAGER_URL" "$tmp_manager" || die "не удалось загрузить менеджер"
    sh -n "$tmp_watchdog" || die "ошибка синтаксиса в загруженном watchdog"
    sh -n "$tmp_manager" || die "ошибка синтаксиса в загруженном менеджере"
    chmod 755 "$tmp_watchdog" "$tmp_manager" || die "не удалось установить права"
    mv "$tmp_watchdog" "$WATCHDOG_PATH" || die "не удалось установить watchdog"
    mv "$tmp_manager" "$MANAGER_PATH" || die "не удалось установить менеджер"
}

detect_interfaces() {
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

load_config() {
    config_file=$1
    JOB_ID=""
    WG_INTERFACE=""
    WG_SERVER_TUNNEL_IP=""
    PING_COUNT=""
    PING_TIMEOUT=""
    RESTART_DELAY=""
    CHECK_INTERVAL=""
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
PING_COUNT='$PING_COUNT'
PING_TIMEOUT='$PING_TIMEOUT'
RESTART_DELAY='$RESTART_DELAY'
CHECK_INTERVAL='$CHECK_INTERVAL'
ENABLED='$ENABLED'
EOF
    chmod 600 "$tmp_config" || die "не удалось установить права на конфигурацию"
    mv "$tmp_config" "$destination" || die "не удалось сохранить $destination"
}

rewrite_crontab() {
    make_temp cron-clean
    clean_file=$REPLY
    make_temp cron-new
    new_file=$REPLY

    if [ -f "$CRONTAB_PATH" ]; then
        cp "$CRONTAB_PATH" "$CRONTAB_PATH.wg-watchdog.bak" 2>/dev/null || true
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
           is_positive_integer "$CHECK_INTERVAL" && [ "$CHECK_INTERVAL" -le 59 ]; then
            printf '*/%s * * * * root %s --job %s\n' \
                "$CHECK_INTERVAL" "$WATCHDOG_PATH" "$JOB_ID" >> "$new_file"
        fi
    done
    printf '%s\n' "$CRON_END" >> "$new_file"
    chmod 600 "$new_file" || die "не удалось установить права на crontab"
    mv "$new_file" "$CRONTAB_PATH" || die "не удалось сохранить crontab"

    /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || die "не удалось запустить cron"
    pidof cron >/dev/null 2>&1 || die "процесс cron не запущен"
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
        ENABLED=yes
        write_config
        mv "$LEGACY_CONFIG" "$LEGACY_CONFIG.migrated-v1.0.0"
        say "Конфигурация v1.0.0 перенесена в формат v1.1.0."
    else
        say "Предупреждение: старую конфигурацию не удалось перенести автоматически."
    fi
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
        old_enabled=$ENABLED
    else
        old_interface=""
        default_server=""
        default_ping_count=3
        default_ping_timeout=3
        default_restart_delay=3
        default_interval=5
        old_enabled=yes
    fi

    choose_interface "$old_interface"
    JOB_ID=$WG_INTERFACE
    if [ -f "$CONFIG_DIR/$JOB_ID.conf" ] && [ "$JOB_ID" != "$original_job" ]; then
        say "Для $JOB_ID уже существует задание. Используйте пункт «Изменить»."
        return 1
    fi

    while :; do
        read_answer "Введите внутренний IP-адрес WireGuard-сервера" "$default_server"
        if valid_address "$REPLY"; then
            WG_SERVER_TUNNEL_IP=$REPLY
            break
        fi
        say "Введите IP-адрес или имя хоста без пробелов."
    done

    say "Проверяю связь с $WG_SERVER_TUNNEL_IP..."
    if ping -c 3 -W 3 "$WG_SERVER_TUNNEL_IP" >/dev/null 2>&1; then
        say "Сервер отвечает на ping."
    else
        say "Сервер не ответил. Возможно, туннель сейчас не работает или ICMP запрещён."
        confirm "Продолжить настройку?" || return 1
    fi

    say "Нажмите Enter, чтобы принять значение в скобках."
    ask_positive_integer PING_COUNT "PING_COUNT — число ping-запросов при проверке" "$default_ping_count"
    ask_positive_integer PING_TIMEOUT "PING_TIMEOUT — ожидание каждого ответа, секунд" "$default_ping_timeout"
    ask_positive_integer RESTART_DELAY "RESTART_DELAY — пауза down/up интерфейса, секунд" "$default_restart_delay"
    ask_interval "$default_interval"
    ENABLED=$old_enabled

    if [ -n "$original_job" ] && [ "$original_job" != "$JOB_ID" ]; then
        rm -f "$CONFIG_DIR/$original_job.conf" "/opt/var/run/wg-watchdog-$original_job.pid"
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
    say "Задание $saved_job сохранено и $saved_state."
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
        printf '  %s) %s — %s; сервер %s; каждые %s мин.; %s\n' \
            "$count" "$WG_INTERFACE" "$description" "$WG_SERVER_TUNNEL_IP" \
            "$CHECK_INTERVAL" "$state"
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
    rm -f "$CONFIG_DIR/$SELECTED_JOB.conf" "/opt/var/run/wg-watchdog-$SELECTED_JOB.pid"
    rewrite_crontab
    say "Задание $SELECTED_JOB удалено."
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
    say "WG Watchdog для KeeneticOS + Entware, версия $VERSION"
    say ""
    say "Менеджер создаёт отдельное задание для каждого WireGuard-интерфейса."
    say "Если интернет работает, но WG-сервер не отвечает, соответствующий"
    say "интерфейс автоматически перезапускается с заданной периодичностью."
    say ""
}

main_menu() {
    while :; do
        say ""
        say "Настроенные задания:"
        build_job_index
        [ "$JOB_COUNT" -gt 0 ] || say "  Нет настроенных заданий."
        say ""
        say "  1) Добавить задание"
        say "  2) Изменить задание"
        say "  3) Включить/выключить задание"
        say "  4) Запустить проверку сейчас"
        say "  5) Удалить задание"
        say "  0) Выход"
        read_answer "Выберите действие" "0"
        case "$REPLY" in
            1) configure_job add "" ;;
            2)
                if [ "$JOB_COUNT" -eq 0 ]; then say "Нет заданий для изменения."
                elif select_job "Какое задание изменить"; then configure_job edit "$SELECTED_JOB"; fi
                ;;
            3) [ "$JOB_COUNT" -gt 0 ] && toggle_job || say "Нет настроенных заданий." ;;
            4) [ "$JOB_COUNT" -gt 0 ] && run_job_now || say "Нет настроенных заданий." ;;
            5) [ "$JOB_COUNT" -gt 0 ] && delete_job || say "Нет настроенных заданий." ;;
            0) return 0 ;;
            *) say "Неизвестный пункт меню." ;;
        esac
    done
}

show_header
ensure_environment
migrate_legacy_config
install_program_files
rewrite_crontab

existing_count=$(find "$CONFIG_DIR" -type f -name '*.conf' 2>/dev/null | wc -l)
if [ "$existing_count" -eq 0 ]; then
    say "Настроенных заданий пока нет. Создадим первое."
    configure_job add ""
fi

main_menu
say "Настройки сохранены. Для управления запустите: $MANAGER_PATH"
exit 0
