#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WATCHDOG="$REPO_DIR/wg-watchdog.sh"
INSTALLER="$REPO_DIR/install.sh"
MANAGER="$REPO_DIR/wg-watchdog-manager.sh"
VERSION_FILE="$REPO_DIR/VERSION"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wg-watchdog-tests.XXXXXX")
TEST_NUMBER=0
PASS_COUNT=0

cleanup_tests() {
    rm -rf "$TEST_ROOT"
}
trap cleanup_tests EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

assert_equal() {
    [ "$1" = "$2" ] || fail "$3: ожидалось '$2', получено '$1'"
}

assert_contains() {
    grep -F -- "$2" "$1" >/dev/null 2>&1 || fail "$3: в $1 нет '$2'"
}

assert_empty() {
    [ ! -s "$1" ] || fail "$2: файл $1 не пуст"
}

new_case() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    CASE_DIR="$TEST_ROOT/case-$TEST_NUMBER"
    CONFIG_DIR="$CASE_DIR/config"
    STATE_DIR="$CASE_DIR/state"
    RUN_DIR="$CASE_DIR/run"
    MOCK_BIN="$CASE_DIR/bin"
    MOCK_DIR="$CASE_DIR/mock"
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$MOCK_BIN" "$MOCK_DIR"
    printf 'boot-test-%s\n' "$TEST_NUMBER" > "$CASE_DIR/boot-id"
    printf '1000.00 0.00\n' > "$CASE_DIR/uptime"
    : > "$MOCK_DIR/ping.log"
    : > "$MOCK_DIR/ndmc.log"
    : > "$MOCK_DIR/logger.log"
    : > "$MOCK_DIR/sleep.log"

    cp "$SCRIPT_DIR/mocks/ping" "$MOCK_BIN/ping"
    cp "$SCRIPT_DIR/mocks/ndmc" "$MOCK_BIN/ndmc"
    cp "$SCRIPT_DIR/mocks/logger" "$MOCK_BIN/logger"
    cp "$SCRIPT_DIR/mocks/sleep" "$MOCK_BIN/sleep"
    cp "$SCRIPT_DIR/mocks/date" "$MOCK_BIN/date"
    chmod 755 "$MOCK_BIN"/*
}

write_config() {
    tunnel=$1
    public=$2
    threshold=$3
    enabled=$4
    internet_check=${5:-yes}
    cat > "$CONFIG_DIR/Wireguard0.conf" <<EOF
JOB_ID='Wireguard0'
WG_INTERFACE='Wireguard0'
WG_SERVER_TUNNEL_IP='$tunnel'
WG_SERVER_PUBLIC_IP='$public'
PING_COUNT='3'
PING_TIMEOUT='3'
RESTART_DELAY='3'
CHECK_INTERVAL='5'
INTERNET_CHECK='$internet_check'
FAILURE_THRESHOLD='$threshold'
RESTART_COOLDOWN='30'
BOOT_GRACE='180'
RECOVERY_CHECK_DELAY='15'
ENABLED='$enabled'
EOF
    chmod 600 "$CONFIG_DIR/Wireguard0.conf"
}

run_watchdog() {
    scenario=$1
    now=$2
    shift 2
    MOCK_SCENARIO="$scenario" \
    MOCK_NOW="$now" \
    MOCK_DIR="$MOCK_DIR" \
    WG_WATCHDOG_CONFIG_DIR="$CONFIG_DIR" \
    WG_WATCHDOG_STATE_DIR="$STATE_DIR" \
    WG_WATCHDOG_RUN_DIR="$RUN_DIR" \
    WG_WATCHDOG_BOOT_ID_FILE="$CASE_DIR/boot-id" \
    WG_WATCHDOG_UPTIME_FILE="$CASE_DIR/uptime" \
    WG_WATCHDOG_PING="$MOCK_BIN/ping" \
    WG_WATCHDOG_NDMC="$MOCK_BIN/ndmc" \
    WG_WATCHDOG_LOGGER="$MOCK_BIN/logger" \
    WG_WATCHDOG_SLEEP="$MOCK_BIN/sleep" \
    WG_WATCHDOG_PATH="$MOCK_BIN:/usr/bin:/bin" \
        sh "$WATCHDOG" --job Wireguard0 "$@"
}

load_test_state() {
    # shellcheck disable=SC1090
    . "$STATE_DIR/Wireguard0.state"
}

# Пауза после загрузки.
new_case
write_config 10.0.0.1 "" 2 yes
printf '0.25 0.00\n' > "$CASE_DIR/uptime"
run_watchdog healthy 1000 --force >/dev/null
load_test_state
assert_equal "$LAST_RESULT" "пауза после загрузки роутера" "boot grace"
assert_empty "$MOCK_DIR/ndmc.log" "boot grace не должен перезапускать интерфейс"
pass "boot grace откладывает проверку"

# Исправный туннель.
new_case
write_config 10.0.0.1 "" 2 yes
run_watchdog healthy 2000 --force >/dev/null
load_test_state
assert_equal "$LAST_RESULT" "туннель работает" "здоровый туннель"
assert_equal "$CONSECUTIVE_FAILURES" 0 "счётчик исправного туннеля"
assert_empty "$MOCK_DIR/ndmc.log" "исправный туннель не должен перезапускаться"
pass "исправный туннель не перезапускается"

# Первая ошибка не приводит к перезапуску, вторая восстанавливает интерфейс.
new_case
write_config 10.0.0.1 "" 2 yes
run_watchdog tunnel_down 3000 --force >/dev/null
load_test_state
assert_equal "$CONSECUTIVE_FAILURES" 1 "первая ошибка"
assert_empty "$MOCK_DIR/ndmc.log" "первая ошибка не должна перезапускать интерфейс"
run_watchdog recover_after_restart 3300 --force >/dev/null
load_test_state
assert_equal "$LAST_RESULT" "туннель восстановлен" "восстановление после второй ошибки"
assert_equal "$CONSECUTIVE_FAILURES" 0 "сброс счётчика после восстановления"
assert_contains "$MOCK_DIR/ndmc.log" "interface Wireguard0 down" "команда down"
assert_contains "$MOCK_DIR/ndmc.log" "interface Wireguard0 up" "команда up"
pass "порог из двух ошибок и восстановление работают"

# Cooldown блокирует повторный перезапуск.
new_case
write_config 10.0.0.1 "" 1 yes
run_watchdog tunnel_down 4000 --force >/dev/null
: > "$MOCK_DIR/ndmc.log"
printf '1060.00 0.00\n' > "$CASE_DIR/uptime"
run_watchdog tunnel_down 4060 --force >/dev/null
load_test_state
assert_contains "$STATE_DIR/Wireguard0.state" "LAST_RESULT='cooldown" "состояние cooldown"
assert_empty "$MOCK_DIR/ndmc.log" "cooldown должен блокировать повторный restart"
pass "cooldown ограничивает повторные перезапуски"

# После завершения cooldown перезапуск снова разрешён.
: > "$MOCK_DIR/ndmc.log"
printf '2861.00 0.00\n' > "$CASE_DIR/uptime"
run_watchdog tunnel_down 5801 --force >/dev/null
assert_contains "$MOCK_DIR/ndmc.log" "interface Wireguard0 down" "restart после cooldown"
pass "после окончания cooldown восстановление снова разрешено"

# Отсутствие интернета не считается ошибкой WireGuard.
new_case
write_config 10.0.0.1 "" 2 yes
run_watchdog tunnel_down 5000 --force >/dev/null
run_watchdog internet_down 5300 --force >/dev/null
load_test_state
assert_equal "$CONSECUTIVE_FAILURES" 0 "сброс при отсутствии интернета"
assert_equal "$LAST_RESULT" "обычный интернет недоступен" "результат проверки интернета"
assert_empty "$MOCK_DIR/ndmc.log" "без интернета restart не нужен"
pass "отсутствие интернета корректно отделяется от ошибки WG"

# Одинаковая длительная ошибка пишется в системный журнал только один раз.
run_watchdog internet_down 5600 --force > "$CASE_DIR/manual-repeat"
internet_log_count=$(grep -c 'интернет недоступен' "$MOCK_DIR/logger.log" || true)
assert_equal "$internet_log_count" 1 "подавление повторного логирования"
assert_contains "$CASE_DIR/manual-repeat" 'интернет недоступен' "результат ручной проверки"
pass "повторяющееся состояние не засоряет системный журнал"

# Full-tunnel jobs can disable probes which might themselves use WireGuard.
new_case
write_config 10.0.0.1 "" 1 yes no
run_watchdog internet_and_tunnel_down 5700 --force >/dev/null
assert_contains "$MOCK_DIR/ndmc.log" "interface Wireguard0 down" "full-tunnel restart"
if grep -F '1.1.1.1' "$MOCK_DIR/ping.log" >/dev/null || \
   grep -F '8.8.8.8' "$MOCK_DIR/ping.log" >/dev/null; then
    fail "выключенная проверка интернета всё равно отправила ping"
fi
pass "выключенная внешняя проверка не блокирует восстановление full-tunnel"

# Monotonic uptime, not a backward wall-clock correction, controls cooldown.
new_case
write_config 10.0.0.1 "" 1 yes no
run_watchdog tunnel_down 10000 --force >/dev/null
: > "$MOCK_DIR/ndmc.log"
printf '1060.00 0.00\n' > "$CASE_DIR/uptime"
run_watchdog tunnel_down 100 --force >/dev/null
assert_empty "$MOCK_DIR/ndmc.log" "перевод часов назад обошёл cooldown"
assert_contains "$STATE_DIR/Wireguard0.state" "LAST_RESULT='cooldown" "монотонный cooldown"
pass "перевод системных часов назад не отменяет cooldown"

# Недоступный публичный сервер блокирует restart.
new_case
write_config 10.0.0.1 public.example 1 yes
run_watchdog public_down 6000 --force >/dev/null
load_test_state
assert_equal "$LAST_RESULT" "публичный адрес WG-сервера недоступен" "публичная проверка"
assert_equal "$CONSECUTIVE_FAILURES" 0 "публичная ошибка не считается ошибкой туннеля"
assert_empty "$MOCK_DIR/ndmc.log" "выключенный сервер не должен вызывать restart"
pass "проверка публичного адреса предотвращает бессмысленный restart"

# DNS-ошибка внутреннего имени учитывается как одна проверка, а не как потерянные пакеты.
new_case
write_config vpn.example.invalid "" 2 yes
run_watchdog dns_failure 7000 --force >/dev/null
load_test_state
assert_equal "$CONSECUTIVE_FAILURES" 1 "DNS-ошибка"
assert_contains "$MOCK_DIR/ping.log" "vpn.example.invalid" "проверка DNS-имени"
assert_empty "$MOCK_DIR/ndmc.log" "одна DNS-ошибка не должна вызывать restart"
pass "DNS-ошибка проходит через общий порог отказов"

# Отключённое задание запускается только вручную с --force.
new_case
write_config 10.0.0.1 "" 2 no
run_watchdog healthy 8000 >/dev/null
[ ! -e "$STATE_DIR/Wireguard0.state" ] || fail "отключённое задание запустилось из cron"
run_watchdog healthy 8000 --force >/dev/null
[ -e "$STATE_DIR/Wireguard0.state" ] || fail "ручная проверка отключённого задания не запустилась"
pass "флаг --force работает только для ручной проверки"

# Ошибка ndmc возвращает ненулевой код и сохраняет диагноз.
new_case
write_config 10.0.0.1 "" 1 yes
if run_watchdog ndmc_fail_down 9000 --force >/dev/null; then
    fail "ошибка ndmc down не вернула ненулевой код"
fi
load_test_state
assert_equal "$LAST_RESULT" "ошибка выключения интерфейса" "ошибка ndmc"
pass "ошибка ndmc диагностируется"

# Устаревшая блокировка удаляется безопасно.
new_case
write_config 10.0.0.1 "" 2 yes
mkdir "$RUN_DIR/wg-watchdog-Wireguard0.lock"
printf '999999\n' > "$RUN_DIR/wg-watchdog-Wireguard0.lock/pid"
run_watchdog healthy 10000 --force >/dev/null
load_test_state
assert_equal "$LAST_RESULT" "туннель работает" "устаревшая блокировка"
[ ! -d "$RUN_DIR/wg-watchdog-Wireguard0.lock" ] || fail "блокировка не очищена"
pass "устаревшая блокировка не мешает проверке"

# Смена boot-id сбрасывает накопленные до перезагрузки ошибки.
new_case
write_config 10.0.0.1 "" 2 yes
run_watchdog tunnel_down 11000 --force >/dev/null
printf 'boot-after-restart\n' > "$CASE_DIR/boot-id"
run_watchdog tunnel_down 11300 --force >/dev/null
load_test_state
assert_equal "$CONSECUTIVE_FAILURES" 1 "сброс ошибок после reboot"
assert_empty "$MOCK_DIR/ndmc.log" "старая ошибка не должна переживать reboot"
pass "новая загрузка сбрасывает накопленные ошибки"

# Выходящие за безопасные пределы параметры отвергаются до вызова ndmc.
new_case
write_config 10.0.0.1 "" 2 yes
sed -i "s/PING_COUNT='3'/PING_COUNT='999'/" "$CONFIG_DIR/Wireguard0.conf"
if run_watchdog tunnel_down 12000 --force >/dev/null; then
    fail "недопустимый PING_COUNT был принят"
fi
assert_empty "$MOCK_DIR/ndmc.log" "ошибочная конфигурация не должна вызывать ndmc"
pass "опасные числовые значения отклоняются"

new_case
write_config 10.0.0.1 "" 2 yes
sed -i "s/PING_COUNT='3'/PING_COUNT='03'/" "$CONFIG_DIR/Wireguard0.conf"
if run_watchdog healthy 12100 --force >/dev/null; then
    fail "PING_COUNT с ведущим нулём был принят"
fi
assert_empty "$MOCK_DIR/ndmc.log" "неоднозначное число не должно вызывать ndmc"
pass "watchdog отклоняет числовые параметры с ведущими нулями"

# Неизвестный режим внешней проверки не должен молча менять сетевую логику.
new_case
write_config 10.0.0.1 "" 2 yes no
sed -i "s/INTERNET_CHECK='no'/INTERNET_CHECK='maybe'/" "$CONFIG_DIR/Wireguard0.conf"
if run_watchdog healthy 7100 --force >/dev/null; then
    fail "неизвестный режим проверки интернета принят"
fi
assert_contains "$MOCK_DIR/logger.log" 'недопустимый режим проверки интернета' "валидация INTERNET_CHECK"
assert_empty "$MOCK_DIR/ndmc.log" "ошибочная настройка не должна перезапускать интерфейс"
pass "неизвестный режим внешней проверки отклоняется"

# Конфигурация читается как данные: shell-код, неизвестные ключи и дубликаты запрещены.
new_case
write_config 10.0.0.1 "" 2 yes no
injection_marker="$CASE_DIR/config-code-executed"
printf '%s\n' "RUN_CODE=\$(touch '$injection_marker')" >> "$CONFIG_DIR/Wireguard0.conf"
if run_watchdog healthy 7200 --force >/dev/null; then
    fail "watchdog принял shell-код в конфигурации"
fi
[ ! -e "$injection_marker" ] || fail "watchdog выполнил код из конфигурации"
assert_contains "$MOCK_DIR/logger.log" 'недопустимый формат' "отказ от shell-кода"

new_case
write_config 10.0.0.1 "" 2 yes no
printf "PING_COUNT='4'\n" >> "$CONFIG_DIR/Wireguard0.conf"
if run_watchdog healthy 7300 --force >/dev/null; then
    fail "watchdog принял повторяющийся ключ"
fi
assert_empty "$MOCK_DIR/ndmc.log" "дубликат ключа не должен запускать восстановление"
pass "watchdog не выполняет конфигурацию и отклоняет неизвестные или повторные ключи"

# Чистые функции менеджера: интервалы и cron-выражения.
WG_WATCHDOG_LIB_ONLY=yes
export WG_WATCHDOG_LIB_ONLY
# shellcheck disable=SC1090
. "$MANAGER"
trap cleanup_tests EXIT HUP INT TERM

# Менеджер использует тот же строгий формат и не исполняет содержимое файла.
manager_bad_config="$TEST_ROOT/manager-bad.conf"
manager_marker="$TEST_ROOT/manager-code-executed"
cat > "$manager_bad_config" <<EOF
JOB_ID='Wireguard0'
WG_INTERFACE='Wireguard0'
WG_SERVER_TUNNEL_IP='10.0.0.1'
PING_COUNT='3'
PING_TIMEOUT='3'
RESTART_DELAY='3'
CHECK_INTERVAL='5'
INTERNET_CHECK='no'
FAILURE_THRESHOLD='2'
RESTART_COOLDOWN='30'
BOOT_GRACE='180'
RECOVERY_CHECK_DELAY='15'
ENABLED='yes'
RUN_CODE=\$(touch '$manager_marker')
EOF
if load_config "$manager_bad_config"; then fail "менеджер принял shell-код"; fi
[ ! -e "$manager_marker" ] || fail "менеджер выполнил код из конфигурации"
pass "менеджер читает настройки как данные, а не как shell-код"

manager_valid_config="$TEST_ROOT/manager-valid.conf"
sed '/^RUN_CODE=/d' "$manager_bad_config" > "$manager_valid_config"
load_config "$manager_valid_config" Wireguard0 || fail "валидная конфигурация не прочитана"
if load_config "$manager_valid_config" Wireguard1; then
    fail "менеджер принял несовпадение имени файла и JOB_ID"
fi
pass "менеджер проверяет совпадение имени файла, JOB_ID и интерфейса"

if is_positive_integer 01; then fail "число с ведущим нулём принято"; fi
is_positive_integer 10 || fail "обычное положительное число отклонено"
pass "числовые параметры имеют однозначный десятичный формат"

valid_interval 5 || fail "интервал 5 отклонён"
valid_interval 60 || fail "интервал 60 отклонён"
if valid_interval 7; then fail "неточный интервал 7 принят"; fi
cron_schedule 1
assert_equal "$REPLY" '*' "cron каждую минуту"
cron_schedule 5
assert_equal "$REPLY" '*/5' "cron каждые пять минут"
cron_schedule 60
assert_equal "$REPLY" '0' "cron каждый час"
pass "менеджер создаёт точные cron-интервалы"

# Парсер интерфейсов показывает WireGuard и игнорирует остальные интерфейсы.
NDMC_BIN="$SCRIPT_DIR/mocks/ndmc-config"
detect_interfaces
assert_contains_text=$(printf '%s\n' "$INTERFACE_LIST" | grep -F 'Wireguard0' || true)
[ -n "$assert_contains_text" ] || fail "Wireguard0 не найден в running-config"
assert_contains_text=$(printf '%s\n' "$INTERFACE_LIST" | grep -F 'Удалённый офис' || true)
[ -n "$assert_contains_text" ] || fail "описание Wireguard0 не найдено"
assert_contains_text=$(printf '%s\n' "$INTERFACE_LIST" | grep -F 'Wireguard2' || true)
[ -n "$assert_contains_text" ] || fail "Wireguard2 без описания не найден"
if printf '%s\n' "$INTERFACE_LIST" | grep -F 'GigabitEthernet0' >/dev/null; then
    fail "обычный интерфейс ошибочно принят за WireGuard"
fi
pass "парсер находит интерфейсы WireGuard и их описания"

# Адреса сервера извлекаются из endpoint и одиночного маршрута allow-ips.
detect_peer_defaults Wireguard0
assert_equal "$DETECTED_PUBLIC_IP" "198.51.100.10" "IPv4 endpoint"
assert_equal "$DETECTED_TUNNEL_IP" "10.0.0.1" "allow-ips с маской"
detect_peer_defaults Wireguard2
assert_equal "$DETECTED_PUBLIC_IP" "wg.example.test" "DNS endpoint"
assert_equal "$DETECTED_TUNNEL_IP" "10.2.0.1" "allow-ips в CIDR"
pass "адреса сервера автоматически извлекаются из выбранного пира"

# При нескольких пирах выбранная строка определяет обе связанные подсказки.
printf '2\n' > "$TEST_ROOT/peer-answer"
INPUT_DEVICE="$TEST_ROOT/peer-answer"
OUTPUT_DEVICE="$TEST_ROOT/peer-prompt"
open_console
detect_peer_defaults Wireguard3 >/dev/null
assert_equal "$DETECTED_PUBLIC_IP" "2001:db8::10" "IPv6 endpoint второго пира"
assert_equal "$DETECTED_TUNNEL_IP" "10.3.0.10" "внутренний адрес второго пира"
pass "при нескольких пирах адреса берутся из выбранного пира"

# Enter подтверждает продолжение, явный отрицательный ответ отменяет его.
printf '\n' > "$TEST_ROOT/answer-yes"
INPUT_DEVICE="$TEST_ROOT/answer-yes"
OUTPUT_DEVICE="$TEST_ROOT/prompt"
open_console
confirm_yes "Продолжить" || fail "Enter не подтвердил продолжение"
assert_contains "$OUTPUT_DEVICE" '[Y/n]' "обозначение подтверждения по умолчанию"
printf 'н\n' > "$TEST_ROOT/answer-no"
INPUT_DEVICE="$TEST_ROOT/answer-no"
open_console
if confirm_yes "Продолжить"; then fail "ответ 'н' не отменил продолжение"; fi
printf '\n' > "$TEST_ROOT/answer-default-no"
INPUT_DEVICE="$TEST_ROOT/answer-default-no"
open_console
if confirm "Использовать публичную проверку"; then
    fail "Enter включил необязательную публичную проверку"
fi
assert_contains "$OUTPUT_DEVICE" '[y/N]' "обозначение необязательного подтверждения"
printf 'yes\n' > "$TEST_ROOT/answer-explicit-yes"
INPUT_DEVICE="$TEST_ROOT/answer-explicit-yes"
open_console
confirm "Использовать публичную проверку" || fail "ответ yes не принят"
pass "подтверждения используют yes/no и безопасные значения по умолчанию"

# Full-screen confirmation is placed directly below the action result.
(
    printf '\n' > "$TEST_ROOT/pause-answer"
    : > "$TEST_ROOT/pause-output"
    INPUT_DEVICE="$TEST_ROOT/pause-answer"
    OUTPUT_DEVICE="$TEST_ROOT/pause-output"
    open_console
    UI_ACTIVE=yes
    UI_ROW=5
    UI_ROWS=24
    ui_pause >/dev/null
    near_result=$(printf '\033[6;1H\033[2KНажмите Enter, чтобы продолжить: ')
    bottom_prompt=$(printf '\033[24;1H\033[2KНажмите Enter, чтобы продолжить: ')
    assert_contains "$TEST_ROOT/pause-output" "$near_result" "положение подтверждения"
    if grep -F "$bottom_prompt" "$TEST_ROOT/pause-output" >/dev/null; then
        fail "подтверждение осталось у нижней границы терминала"
    fi
)
pass "подтверждение Enter показывается под основным текстом"

# Полный диалог создания задания: Enter оставляет публичную проверку выключенной.
prepare_dialog_case() {
    dialog_name=$1
    DIALOG_ROOT="$TEST_ROOT/$dialog_name"
    CONFIG_DIR="$DIALOG_ROOT/config"
    STATE_DIR="$DIALOG_ROOT/state"
    RUN_DIR="$DIALOG_ROOT/run"
    TMP_DIR="$DIALOG_ROOT/tmp"
    CRONTAB_PATH="$DIALOG_ROOT/crontab"
    CRON_INIT=/bin/true
    PIDOF_BIN=/bin/true
    WATCHDOG_PATH=/opt/bin/wg-watchdog.sh
    NDMC_BIN="$SCRIPT_DIR/mocks/ndmc-config"
    PING_BIN="$SCRIPT_DIR/mocks/ping"
    MOCK_DIR="$DIALOG_ROOT/mock"
    MOCK_SCENARIO=healthy
    export MOCK_DIR MOCK_SCENARIO
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$TMP_DIR" "$MOCK_DIR"
    : > "$MOCK_DIR/ping.log"
    INPUT_DEVICE="$DIALOG_ROOT/answers"
    OUTPUT_DEVICE="$DIALOG_ROOT/prompts"
}

prepare_dialog_case manager-default-public-off
printf '1\n\n\n' > "$INPUT_DEVICE"
open_console
configure_job add "" > "$DIALOG_ROOT/output"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "WG_SERVER_TUNNEL_IP='10.0.0.1'" "автоподстановка внутреннего адреса"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "WG_SERVER_PUBLIC_IP=''" "публичная проверка по умолчанию"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "PING_COUNT='3'" "PING_COUNT по умолчанию"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "CHECK_INTERVAL='5'" "CHECK_INTERVAL по умолчанию"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "FAILURE_THRESHOLD='2'" "порог по умолчанию"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "INTERNET_CHECK='no'" "безопасный режим full-tunnel"
if grep -F 'PING_COUNT —' "$OUTPUT_DEVICE" >/dev/null || \
   grep -F 'CHECK_INTERVAL —' "$OUTPUT_DEVICE" >/dev/null; then
    fail "при создании задания запрошены числовые параметры"
fi
assert_contains "$DIALOG_ROOT/output" 'Применены рекомендуемые параметры:' "summary параметров задания"
assert_contains "$DIALOG_ROOT/output" 'Изменить эти значения можно' "подсказка редактирования"
pass "новое задание получает рекомендуемые параметры без лишних вопросов"

# Редактирование существующего задания не спрашивает интерфейс повторно.
printf '\n\n\n\n\n\n\n\n\n\n\n' > "$INPUT_DEVICE"
open_console
configure_job edit Wireguard0 >/dev/null
if grep -F 'Выберите номер интерфейса' "$OUTPUT_DEVICE" >/dev/null; then
    fail "при редактировании повторно запрошен WireGuard-интерфейс"
fi
assert_contains "$OUTPUT_DEVICE" 'Введите внутренний IP-адрес WireGuard-сервера' "диалог редактирования"
pass "редактирование сохраняет интерфейс без повторного выбора"

# Явный yes включает проверку и предлагает Endpoint в качестве адреса.
prepare_dialog_case manager-public-opt-in
printf '1\n\ny\n\n' > "$INPUT_DEVICE"
open_console
configure_job add "" >/dev/null
assert_contains "$CONFIG_DIR/Wireguard0.conf" "WG_SERVER_PUBLIC_IP='198.51.100.10'" "публичный Endpoint"
pass "явный yes включает проверку найденного публичного адреса"

# Обновление конфигурации v1.1 добавляет новые параметры и исправляет неточный cron-интервал.
MANAGER_ROOT="$TEST_ROOT/manager"
CONFIG_DIR="$MANAGER_ROOT/config"
STATE_DIR="$MANAGER_ROOT/state"
RUN_DIR="$MANAGER_ROOT/run"
TMP_DIR="$MANAGER_ROOT/tmp"
CRONTAB_PATH="$MANAGER_ROOT/crontab"
CRON_INIT=/bin/true
PIDOF_BIN=/bin/true
WATCHDOG_PATH=/opt/bin/wg-watchdog.sh
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$TMP_DIR"
cat > "$CONFIG_DIR/Wireguard0.conf" <<'EOF'
JOB_ID='Wireguard0'
WG_INTERFACE='Wireguard0'
WG_SERVER_TUNNEL_IP='10.0.0.1'
PING_COUNT='3'
PING_TIMEOUT='3'
RESTART_DELAY='3'
CHECK_INTERVAL='7'
ENABLED='yes'
EOF
upgrade_config_files >/dev/null
assert_contains "$CONFIG_DIR/Wireguard0.conf" "FAILURE_THRESHOLD='2'" "миграция FAILURE_THRESHOLD"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "RESTART_COOLDOWN='30'" "миграция cooldown"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "CHECK_INTERVAL='5'" "нормализация интервала"
assert_contains "$CONFIG_DIR/Wireguard0.conf" "INTERNET_CHECK='yes'" "сохранение прежней сетевой логики"
pass "старая конфигурация обновляется без молчаливой смены сетевой логики"

# Повторный запуск миграции не перезаписывает неизменившийся файл на /opt.
config_inode_before=$(ls -i "$CONFIG_DIR/Wireguard0.conf" | awk '{ print $1 }')
upgrade_config_files >/dev/null
config_inode_after=$(ls -i "$CONFIG_DIR/Wireguard0.conf" | awk '{ print $1 }')
assert_equal "$config_inode_after" "$config_inode_before" "неизменившийся конфиг"
pass "неизменившаяся конфигурация не перезаписывается"

# Перестройка crontab сохраняет чужие строки и создаёт по строке на включённый интерфейс.
cat > "$CRONTAB_PATH" <<EOF
SHELL=/bin/sh
17 * * * * root /opt/bin/custom-task
$CRON_BEGIN
*/9 * * * * root /opt/bin/wg-watchdog.sh --job Wireguard9
$CRON_END
EOF
JOB_ID=Wireguard1
WG_INTERFACE=Wireguard1
WG_SERVER_TUNNEL_IP=10.0.1.1
WG_SERVER_PUBLIC_IP=""
PING_COUNT=3
PING_TIMEOUT=3
RESTART_DELAY=3
CHECK_INTERVAL=10
INTERNET_CHECK=no
FAILURE_THRESHOLD=2
RESTART_COOLDOWN=30
BOOT_GRACE=180
RECOVERY_CHECK_DELAY=15
ENABLED=no
write_config
rewrite_crontab
assert_contains "$CRONTAB_PATH" '/opt/bin/custom-task' "сохранение чужого cron"
assert_contains "$CRONTAB_PATH" '*/5 * * * * root /opt/bin/wg-watchdog.sh --job Wireguard0' "cron Wireguard0"
if grep -F 'Wireguard1' "$CRONTAB_PATH" >/dev/null; then
    fail "отключённое задание попало в crontab"
fi
if grep -F 'Wireguard9' "$CRONTAB_PATH" >/dev/null; then
    fail "устаревшая управляемая строка осталась в crontab"
fi
assert_contains "$CRONTAB_PATH.wg-watchdog.bak" 'Wireguard9' "резервная копия cron"
pass "crontab сохраняет чужие строки и исключает отключённые задания"

# Включённые и выключенные задания имеют разные цвета и номер с точкой.
COLOR_GREEN='<GREEN>'
COLOR_RED='<RED>'
COLOR_RESET='</GREEN>'
NDMC_BIN="$SCRIPT_DIR/mocks/ndmc-config"
build_job_index > "$MANAGER_ROOT/job-list"
assert_contains "$MANAGER_ROOT/job-list" '<GREEN>1. Wireguard0' "формат номера задания"
assert_contains "$MANAGER_ROOT/job-list" '<RED>2. Wireguard1' "цвет выключенного задания"
if grep -F '<GREEN>1) Wireguard0' "$MANAGER_ROOT/job-list" >/dev/null; then
    fail "задание использует тот же формат номера, что и действие меню"
fi
COLOR_GREEN=''
COLOR_RED=''
COLOR_RESET=''
pass "состояния заданий различаются цветом и нумеруются с точкой"

# Каждый пункт, работающий с заданием, показывает список без выбора по Enter и позволяет вернуться.
ACTION_ROOT="$TEST_ROOT/job-actions"
mkdir -p "$ACTION_ROOT"
for menu_action in 2 3 4 5 6; do
    printf '%s\n\n0\n0\n' "$menu_action" > "$ACTION_ROOT/input"
    INPUT_DEVICE="$ACTION_ROOT/input"
    OUTPUT_DEVICE="$ACTION_ROOT/prompts"
    open_console
    if ! main_menu > "$ACTION_ROOT/output-$menu_action"; then
        fail "пункт $menu_action не вернулся в главное меню"
    fi
    assert_contains "$ACTION_ROOT/output-$menu_action" '1. Wireguard0' "список задания для пункта $menu_action"
    assert_contains "$ACTION_ROOT/output-$menu_action" '0) Вернуться в главное меню' "возврат из пункта $menu_action"
    assert_contains "$ACTION_ROOT/output-$menu_action" 'Введите номер от 1 до 2 или 0 для возврата.' "Enter без значения для пункта $menu_action"
    if grep -F 'Какое задание' "$OUTPUT_DEVICE" | grep -F '[1]' >/dev/null 2>&1 || \
       grep -F 'Выберите задание [1]' "$OUTPUT_DEVICE" >/dev/null 2>&1; then
        fail "в пункте $menu_action осталось задание по умолчанию"
    fi
done
pass "все действия показывают задания, не выбирают первое по Enter и имеют возврат"

# Повторная сборка идентичного crontab не меняет файл и резервную копию.
cron_inode_before=$(ls -i "$CRONTAB_PATH" | awk '{ print $1 }')
backup_inode_before=$(ls -i "$CRONTAB_PATH.wg-watchdog.bak" | awk '{ print $1 }')
rewrite_crontab
cron_inode_after=$(ls -i "$CRONTAB_PATH" | awk '{ print $1 }')
backup_inode_after=$(ls -i "$CRONTAB_PATH.wg-watchdog.bak" | awk '{ print $1 }')
assert_equal "$cron_inode_after" "$cron_inode_before" "неизменившийся crontab"
assert_equal "$backup_inode_after" "$backup_inode_before" "неизменившаяся резервная копия"
pass "неизменившийся crontab не записывается повторно"

# Часто изменяемые файлы по умолчанию должны находиться в RAM, а не на /opt.
assert_contains "$WATCHDOG" 'STATE_DIR="${WG_WATCHDOG_STATE_DIR:-/tmp/wg-watchdog}"' "RAM state dir"
assert_contains "$WATCHDOG" 'RUN_DIR="${WG_WATCHDOG_RUN_DIR:-/tmp/wg-watchdog}"' "RAM lock dir"
pass "состояние и блокировки по умолчанию размещены в RAM"

# Версии исполняемых файлов должны совпадать. Legacy-файл VERSION намеренно
# остаётся на 1.5.4, чтобы старый менеджер не запустил последовательное обновление.
legacy_version=$(sed -n '1p' "$VERSION_FILE")
manager_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$MANAGER" | head -n 1)
watchdog_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$WATCHDOG" | head -n 1)
installer_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$INSTALLER" | head -n 1)
assert_equal "$watchdog_version" "$manager_version" "версия watchdog"
assert_equal "$installer_version" "$manager_version" "версия установщика"
assert_equal "$legacy_version" 1.5.4 "защитная версия старого канала обновлений"
pass "версии исполняемых файлов совпадают, старый канал обновлений заморожен"

# Семантическое сравнение и строгий манифест выпуска.
version_is_newer 1.10.0 1.9.9 || fail "1.10.0 не распознана как новая версия"
if version_is_newer 1.2.9 1.3.0; then fail "старая версия распознана как новая"; fi
cat > "$TEST_ROOT/remote-release" <<'EOF'
VERSION=1.9.0
COMMIT=0123456789abcdef0123456789abcdef01234567
WATCHDOG_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MANAGER_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
RELEASE_MANIFEST_URL="$TEST_ROOT/remote-release"
download_file() { cp "$1" "$2"; }
check_update_status
assert_equal "$UPDATE_AVAILABLE" yes "доступность обновления"
assert_equal "$REMOTE_VERSION" 1.9.0 "номер удалённой версии"
assert_equal "$REMOTE_COMMIT" 0123456789abcdef0123456789abcdef01234567 "commit выпуска"
printf 'EXTRA=value\n' >> "$TEST_ROOT/remote-release"
check_update_status
assert_equal "$UPDATE_AVAILABLE" unknown "лишнее поле манифеста"
pass "обновление использует строгий манифест и корректное сравнение версий"

# Короткая команда создаётся только в свободном месте и не затирает коллизию.
SHORT_COMMAND="$TEST_ROOT/bin-free/wgwm"
MANAGER_PATH="$TEST_ROOT/bin-free/wg-watchdog-manager"
mkdir -p "$TEST_ROOT/bin-free"
: > "$MANAGER_PATH"
ensure_short_command
[ -L "$SHORT_COMMAND" ] || fail "символическая ссылка wgwm не создана"
assert_equal "$(readlink "$SHORT_COMMAND")" "$MANAGER_PATH" "назначение wgwm"
rm -f "$SHORT_COMMAND"
printf 'чужая команда\n' > "$SHORT_COMMAND"
ensure_short_command > "$TEST_ROOT/wgwm-collision"
assert_contains "$SHORT_COMMAND" 'чужая команда' "защита занятого имени wgwm"
assert_contains "$TEST_ROOT/wgwm-collision" 'уже занят' "сообщение о коллизии wgwm"
pass "команда wgwm создаётся безопасно"

# Шапка содержит назначение, автора и версию; интерфейсы выводятся отдельным блоком.
COLOR_CYAN=''
COLOR_RESET=''
show_header > "$TEST_ROOT/header"
assert_contains "$TEST_ROOT/header" 'WG Watchdog Manager' "заголовок"
assert_contains "$TEST_ROOT/header" 'Автор: org1org' "автор"
assert_contains "$TEST_ROOT/header" "Версия: $VERSION" "версия в шапке"
NDMC_BIN="$SCRIPT_DIR/mocks/ndmc-config"
(
    cat > "$CONFIG_DIR/Wireguard2.conf" <<'EOF'
JOB_ID='Wireguard2'
WG_INTERFACE='Wireguard2'
ENABLED='no'
EOF
    COLOR_GREEN='<GREEN>'
    COLOR_RED='<RED>'
    COLOR_GRAY='<GRAY>'
    COLOR_RESET='</COLOR>'
    show_detected_interfaces > "$TEST_ROOT/interfaces"
)
assert_contains "$TEST_ROOT/interfaces" 'WireGuard-интерфейсы:' "заголовок интерфейсов"
assert_contains "$TEST_ROOT/interfaces" '<GREEN>  Wireguard0 — включена · Удалённый офис' "включённый интерфейс"
assert_contains "$TEST_ROOT/interfaces" '<RED>  Wireguard2 — выключена · без описания' "выключенный интерфейс"
assert_contains "$TEST_ROOT/interfaces" '<GRAY>  Wireguard3 — Два пира</COLOR>' "ненастроенный интерфейс"
pass "все интерфейсы показываются со статусом и цветом проверки"

# Набор действий зависит от наличия настроенных заданий.
MENU_ROOT="$TEST_ROOT/menu"
mkdir -p "$MENU_ROOT/empty" "$MENU_ROOT/tmp"
CONFIG_DIR="$MENU_ROOT/empty"
TMP_DIR="$MENU_ROOT/tmp"
printf '0\n' > "$MENU_ROOT/input-empty"
INPUT_DEVICE="$MENU_ROOT/input-empty"
OUTPUT_DEVICE="$MENU_ROOT/prompts-empty"
open_console
UPDATE_AVAILABLE=no
main_menu > "$MENU_ROOT/menu-empty"
assert_contains "$MENU_ROOT/menu-empty" '1) Добавить задание' "добавление без заданий"
assert_contains "$MENU_ROOT/menu-empty" '2) Проверить обновления' "обновление без заданий"
assert_contains "$MENU_ROOT/menu-empty" '3) Удалить WG Watchdog' "удаление без заданий"
if grep -F 'Изменить задание' "$MENU_ROOT/menu-empty" >/dev/null; then
    fail "без заданий показано полное меню"
fi

CONFIG_DIR="$MANAGER_ROOT/config"
TMP_DIR="$MANAGER_ROOT/tmp"
printf '0\n' > "$MENU_ROOT/input-full"
INPUT_DEVICE="$MENU_ROOT/input-full"
OUTPUT_DEVICE="$MENU_ROOT/prompts-full"
open_console
main_menu > "$MENU_ROOT/menu-full"
assert_contains "$MENU_ROOT/menu-full" '2) Изменить задание' "полное меню"
assert_contains "$MENU_ROOT/menu-full" '7) Проверить обновления' "обновление в полном меню"
assert_contains "$MENU_ROOT/menu-full" '8) Удалить WG Watchdog' "удаление в полном меню"
pass "меню сокращается, когда заданий ещё нет"

# Менеджер запускается без лишнего подтверждения, а установщик не стартует его после первой установки.
if grep -F 'confirm_yes "Продолжить?' "$MANAGER" >/dev/null; then
    fail "wgwm всё ещё спрашивает подтверждение запуска"
fi
assert_contains "$INSTALLER" 'confirm_yes "Установить WG Watchdog?"' "подтверждение первой установки"
assert_contains "$INSTALLER" 'show_summary' "итог первой установки"
pass "подтверждение осталось только у первой установки"

# Полное удаление убирает только файлы программы и её блок cron.
UNINSTALL_ROOT="$TEST_ROOT/uninstall"
CONFIG_DIR="$UNINSTALL_ROOT/config"
STATE_DIR="$UNINSTALL_ROOT/state"
RUN_DIR="$UNINSTALL_ROOT/state"
TMP_DIR="$UNINSTALL_ROOT/tmp"
CRONTAB_PATH="$UNINSTALL_ROOT/crontab"
CRON_INIT=/bin/true
WATCHDOG_PATH="$UNINSTALL_ROOT/bin/wg-watchdog.sh"
LEGACY_CONFIG="$UNINSTALL_ROOT/legacy.conf"
MANAGER_PATH="$UNINSTALL_ROOT/bin/wg-watchdog-manager"
SHORT_COMMAND="$UNINSTALL_ROOT/bin/wgwm"
mkdir -p "$CONFIG_DIR" "$STATE_DIR/wg-watchdog-Wireguard0.lock" "$TMP_DIR" "$UNINSTALL_ROOT/bin"
: > "$CONFIG_DIR/Wireguard0.conf"
: > "$STATE_DIR/Wireguard0.state"
printf '99999999\n' > "$STATE_DIR/wg-watchdog-Wireguard0.lock/pid"
: > "$WATCHDOG_PATH"
: > "$MANAGER_PATH"
ln -s "$MANAGER_PATH" "$SHORT_COMMAND"
cat > "$CRONTAB_PATH" <<EOF
17 * * * * root /opt/bin/foreign-task
$CRON_BEGIN
*/5 * * * * root /opt/bin/wg-watchdog.sh --job Wireguard0
$CRON_END
EOF
printf '2\nyes\n' > "$UNINSTALL_ROOT/answer"
INPUT_DEVICE="$UNINSTALL_ROOT/answer"
OUTPUT_DEVICE="$UNINSTALL_ROOT/prompt"
open_console
(uninstall_program > "$UNINSTALL_ROOT/output")
[ ! -e "$WATCHDOG_PATH" ] || fail "watchdog остался после удаления"
[ ! -e "$MANAGER_PATH" ] || fail "менеджер остался после удаления"
[ ! -e "$SHORT_COMMAND" ] || fail "wgwm осталась после удаления"
[ ! -e "$CONFIG_DIR/Wireguard0.conf" ] || fail "конфигурация осталась после удаления"
assert_contains "$CRONTAB_PATH" '/opt/bin/foreign-task' "сохранение стороннего cron при удалении"
if grep -F 'wg-watchdog.sh' "$CRONTAB_PATH" >/dev/null; then
    fail "строка watchdog осталась в cron после удаления"
fi
pass "штатное удаление сохраняет сторонние задания cron"

# Program-only uninstall keeps job configs but disables cron and clears RAM state.
(
    keep_root="$TEST_ROOT/uninstall-keep-jobs"
    CONFIG_DIR="$keep_root/config"
    STATE_DIR="$keep_root/state"
    RUN_DIR="$keep_root/run"
    TMP_DIR="$keep_root/tmp"
    CRONTAB_PATH="$keep_root/crontab"
    CRON_INIT=/bin/true
    WATCHDOG_PATH="$keep_root/bin/wg-watchdog.sh"
    MANAGER_PATH="$keep_root/bin/wg-watchdog-manager"
    SHORT_COMMAND="$keep_root/bin/wgwm"
    LEGACY_CONFIG="$keep_root/legacy.conf"
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$TMP_DIR" "$keep_root/bin"
    printf "JOB_ID='Wireguard0'\n" > "$CONFIG_DIR/Wireguard0.conf"
    printf "LAST_RESULT='туннель работает'\n" > "$STATE_DIR/Wireguard0.state"
    : > "$WATCHDOG_PATH"
    : > "$MANAGER_PATH"
    ln -s "$MANAGER_PATH" "$SHORT_COMMAND"
    cat > "$CRONTAB_PATH" <<EOF
17 * * * * root /opt/bin/foreign-task
$CRON_BEGIN
*/5 * * * * root /opt/bin/wg-watchdog.sh --job Wireguard0
$CRON_END
EOF
    printf '1\nyes\n' > "$keep_root/input"
    INPUT_DEVICE="$keep_root/input"
    OUTPUT_DEVICE="$keep_root/output"
    open_console
    uninstall_program > "$keep_root/result"
    exit 99
) || keep_result=$?
assert_equal "${keep_result:-0}" 0 "завершение удаления с сохранением заданий"
[ -f "$TEST_ROOT/uninstall-keep-jobs/config/Wireguard0.conf" ] || fail "сохранённое задание удалено"
[ ! -e "$TEST_ROOT/uninstall-keep-jobs/state/Wireguard0.state" ] || fail "оперативное состояние сохранено без программы"
[ ! -e "$TEST_ROOT/uninstall-keep-jobs/bin/wg-watchdog-manager" ] || fail "менеджер остался"
assert_contains "$TEST_ROOT/uninstall-keep-jobs/crontab" 'foreign-task' "чужой cron при сохранении заданий"
if grep -F 'wg-watchdog.sh' "$TEST_ROOT/uninstall-keep-jobs/crontab" >/dev/null; then
    fail "cron watchdog остался после удаления программы"
fi
assert_contains "$TEST_ROOT/uninstall-keep-jobs/result" 'Настроенные задания сохранены' "summary сохранения заданий"
pass "программу можно удалить, сохранив задания для переустановки"

# Выход из меню удаления ничего не меняет.
(
    cancel_root="$TEST_ROOT/uninstall-cancel"
    CONFIG_DIR="$cancel_root/config"
    STATE_DIR="$cancel_root/state"
    RUN_DIR="$cancel_root/run"
    TMP_DIR="$cancel_root/tmp"
    CRONTAB_PATH="$cancel_root/crontab"
    CRON_INIT=/bin/true
    WATCHDOG_PATH="$cancel_root/bin/wg-watchdog.sh"
    MANAGER_PATH="$cancel_root/bin/wg-watchdog-manager"
    SHORT_COMMAND="$cancel_root/bin/wgwm"
    LEGACY_CONFIG="$cancel_root/legacy.conf"
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$TMP_DIR" "$cancel_root/bin"
    printf "JOB_ID='Wireguard0'\n" > "$CONFIG_DIR/Wireguard0.conf"
    : > "$WATCHDOG_PATH"
    : > "$MANAGER_PATH"
    ln -s "$MANAGER_PATH" "$SHORT_COMMAND"
    printf '%s\n' "$CRON_BEGIN" \
        '*/5 * * * * root /opt/bin/wg-watchdog.sh --job Wireguard0' \
        "$CRON_END" > "$CRONTAB_PATH"
    cp "$CRONTAB_PATH" "$cancel_root/crontab.expected"
    printf '0\n' > "$cancel_root/input"
    INPUT_DEVICE="$cancel_root/input"
    OUTPUT_DEVICE="$cancel_root/output"
    open_console
    uninstall_program >/dev/null
    [ -f "$WATCHDOG_PATH" ] || fail "отмена удаления удалила watchdog"
    [ -f "$MANAGER_PATH" ] || fail "отмена удаления удалила менеджер"
    [ -f "$CONFIG_DIR/Wireguard0.conf" ] || fail "отмена удаления удалила задание"
    cmp -s "$CRONTAB_PATH" "$cancel_root/crontab.expected" || fail "отмена удаления изменила cron"
)
pass "из меню удаления можно вернуться без изменений"

# Жизненный цикл установщика: первая установка, повторный запуск и --force.
INSTALL_ROOT="$TEST_ROOT/installer"
INSTALL_OPT="$INSTALL_ROOT/opt"
INSTALL_TMP="$INSTALL_ROOT/tmp"
INSTALL_MOCK_BIN="$INSTALL_ROOT/mock-bin"
mkdir -p "$INSTALL_OPT/bin" "$INSTALL_TMP" "$INSTALL_MOCK_BIN"
cat > "$INSTALL_MOCK_BIN/id" <<'EOF'
#!/bin/sh
printf '0\n'
EOF
cat > "$INSTALL_MOCK_BIN/wget" <<'EOF'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O) output=$2; shift 2 ;;
        -q) shift ;;
        *) url=$1; shift ;;
    esac
done
if [ "${url##*/}" = RELEASE ]; then
    cp "$MOCK_RELEASE_FILE" "$output"
else
    cp "$MOCK_INSTALL_SOURCE/${url##*/}" "$output"
fi
EOF
chmod 755 "$INSTALL_MOCK_BIN/id" "$INSTALL_MOCK_BIN/wget"
watchdog_release_hash=$(sha256sum "$WATCHDOG" | awk '{ print $1 }')
manager_release_hash=$(sha256sum "$MANAGER" | awk '{ print $1 }')
cat > "$INSTALL_ROOT/RELEASE" <<EOF
VERSION=1.8.0
COMMIT=0123456789abcdef0123456789abcdef01234567
WATCHDOG_SHA256=$watchdog_release_hash
MANAGER_SHA256=$manager_release_hash
EOF
printf '\n' > "$INSTALL_ROOT/answer"
: > "$INSTALL_ROOT/prompt"
installer_env() {
    MOCK_INSTALL_SOURCE="$REPO_DIR" \
    MOCK_RELEASE_FILE="$INSTALL_ROOT/RELEASE" \
    WG_WATCHDOG_OPT_ROOT="$INSTALL_OPT" \
    WG_WATCHDOG_TMP_DIR="$INSTALL_TMP" \
    WG_WATCHDOG_INPUT="$INSTALL_ROOT/answer" \
    WG_WATCHDOG_OUTPUT="$INSTALL_ROOT/prompt" \
    WG_WATCHDOG_OPKG=/bin/true \
    WG_WATCHDOG_RELEASE_MANIFEST_URL="$INSTALL_ROOT/RELEASE" \
    WG_WATCHDOG_RAW_REPOSITORY_URL=https://example.invalid \
    WG_WATCHDOG_RUN_DIR="$INSTALL_ROOT/run" \
    WG_WATCHDOG_STATE_DIR="$INSTALL_ROOT/state" \
    WG_WATCHDOG_PATH="$INSTALL_MOCK_BIN:/usr/bin:/bin" \
    WG_WATCHDOG_INSTALL_PATH="$INSTALL_MOCK_BIN:/usr/bin:/bin" \
        sh "$INSTALLER" "$@"
}
installer_env > "$INSTALL_ROOT/first-output"
assert_contains "$INSTALL_ROOT/prompt" 'Установить WG Watchdog? [Y/n]' "подтверждение установки"
assert_contains "$INSTALL_ROOT/first-output" 'WG Watchdog 1.8.0 установлен.' "summary установки"
assert_contains "$INSTALL_ROOT/first-output" 'Принудительно переустановить:' "команда переустановки"
[ -x "$INSTALL_OPT/bin/wg-watchdog-manager" ] || fail "менеджер не установлен"
[ -L "$INSTALL_OPT/bin/wgwm" ] || fail "wgwm не создана установщиком"
pass "первая установка завершается summary без автозапуска"

cat > "$INSTALL_OPT/bin/wg-watchdog-manager" <<'EOF'
#!/bin/sh
VERSION_URL=test
printf 'launched\n' > "$MOCK_MANAGER_LOG"
EOF
chmod 755 "$INSTALL_OPT/bin/wg-watchdog-manager"
MOCK_MANAGER_LOG="$INSTALL_ROOT/manager-launched"
export MOCK_MANAGER_LOG
installer_env > "$INSTALL_ROOT/repeat-output"
assert_contains "$MOCK_MANAGER_LOG" launched "повторный запуск менеджера"
if grep -F 'Загружаю WG Watchdog' "$INSTALL_ROOT/repeat-output" >/dev/null; then
    fail "повторный запуск без --force загрузил файлы"
fi
pass "повторная установочная команда только запускает менеджер"

: > "$INSTALL_ROOT/prompt"
installer_env --force > "$INSTALL_ROOT/force-output"
assert_contains "$INSTALL_OPT/bin/wg-watchdog-manager" 'VERSION="1.8.0"' "принудительная переустановка менеджера"
assert_empty "$INSTALL_ROOT/prompt" "--force не должен спрашивать подтверждение"
assert_contains "$INSTALL_ROOT/force-output" 'WG Watchdog 1.8.0 установлен.' "summary --force"
pass "ключ --force принудительно переустанавливает файлы"

# Regression: cron generation must not replace the caller's selected job.
(
    TMP_FILES=""
    trap cleanup EXIT
    CONFIG_DIR="$MANAGER_ROOT/config"
    CRONTAB_PATH="$MANAGER_ROOT/crontab"
    TMP_DIR="$MANAGER_ROOT/tmp"
    WATCHDOG_PATH=/opt/bin/wg-watchdog.sh
    CRON_INIT=/bin/true
    PIDOF_BIN=/bin/true
    JOB_ID=Wireguard42
    PING_COUNT=7
    CHECK_INTERVAL=30
    rewrite_crontab
    assert_equal "$JOB_ID" Wireguard42 "выбранное задание после сборки cron"
    assert_equal "$PING_COUNT" 7 "параметры выбранного задания"
    assert_equal "$CHECK_INTERVAL" 30 "интервал выбранного задания"
)
pass "сборка cron не меняет переменные выбранного задания"

# Regression: references to our script are not necessarily our commands.
(
    TMP_FILES=""
    trap cleanup EXIT
    TMP_DIR="$TEST_ROOT"
    CRONTAB_PATH="$TEST_ROOT/cron-filter"
    WATCHDOG_PATH=/opt/bin/wg-watchdog.sh
    printf '%s\n' \
        '# backup /opt/bin/wg-watchdog.sh' \
        '1 * * * * root /opt/bin/backup /opt/bin/wg-watchdog.sh' \
        '2 * * * * root /opt/bin/wg-watchdog.sh.backup' \
        '3 * * * * root /opt/bin/wg-watchdog.sh --job Wireguard0' > "$CRONTAB_PATH"
    filter_managed_cron > "$TEST_ROOT/cron-filter-result"
    assert_equal "$(wc -l < "$TEST_ROOT/cron-filter-result" | tr -d ' ')" 3 "сохранение чужих упоминаний"
    assert_contains "$TEST_ROOT/cron-filter-result" 'wg-watchdog.sh.backup' "похожая команда"
    printf '%s\n' "$CRON_BEGIN" 'foreign entry' > "$CRONTAB_PATH"
    cp "$CRONTAB_PATH" "$TEST_ROOT/cron-filter-original"
    CONFIG_DIR="$MANAGER_ROOT/config"
    if rewrite_crontab > /dev/null 2>&1; then fail "принят блок cron без END"; fi
    cmp -s "$CRONTAB_PATH" "$TEST_ROOT/cron-filter-original" || fail "повреждённый cron перезаписан"
)
pass "очистка cron сохраняет чужие упоминания и отклоняет повреждённый блок"

# Regression: tempfile names must be unique, private and work with spaces.
(
    TMP_FILES=""
    trap cleanup EXIT
    TMP_DIR="$TEST_ROOT/temp with spaces"
    mkdir -p "$TMP_DIR"
    make_temp config
    first_temp=$REPLY
    make_temp config
    second_temp=$REPLY
    [ "$first_temp" != "$second_temp" ] || fail "повторно использовано имя временного файла"
    assert_equal "$(stat -c %a "$first_temp")" 600 "права временного файла"
    cleanup
    [ ! -e "$first_temp" ] && [ ! -e "$second_temp" ] || fail "временные файлы не удалены"
)
pass "временные файлы уникальны, закрыты и корректно очищаются"

# Regression: canceling deletion is not an empty job list.
(
    TMP_FILES=""
    trap cleanup EXIT
    prepare_dialog_case cancel-delete
    printf '1\n\n\n' > "$INPUT_DEVICE"
    open_console
    configure_job add "" >/dev/null
    printf '6\n1\nn\n0\n' > "$INPUT_DEVICE"
    open_console
    main_menu > "$DIALOG_ROOT/cancel-output"
    [ -f "$CONFIG_DIR/Wireguard0.conf" ] || fail "отмена удалила задание"
    if grep -F 'Нет настроенных заданий.' "$DIALOG_ROOT/cancel-output" >/dev/null; then
        fail "отмена вызвала ложное сообщение об отсутствии заданий"
    fi
)
pass "отмена удаления не выводит ложное сообщение"

# Regression: editing a multi-peer interface does not reselect the peer.
(
    TMP_FILES=""
    trap cleanup EXIT
    prepare_dialog_case edit-multi-peer
    printf '1\n\n\n' > "$INPUT_DEVICE"
    open_console
    configure_job add "" >/dev/null
    load_config "$CONFIG_DIR/Wireguard0.conf"
    JOB_ID=Wireguard3
    WG_INTERFACE=Wireguard3
    write_config
    printf '\n\n\n\n\n\n\n\n\n\n\n' > "$INPUT_DEVICE"
    open_console
    configure_job edit Wireguard3 > "$DIALOG_ROOT/edit-output"
    if grep -F 'Выберите пир' "$OUTPUT_DEVICE" >/dev/null; then fail "повторный выбор пира при редактировании"; fi
    assert_contains "$CONFIG_DIR/Wireguard3.conf" "WG_SERVER_TUNNEL_IP='10.0.0.1'" "сохранённый адрес"
)
pass "редактирование многопирового интерфейса сохраняет адрес без выбора пира"

# Regression: --force on an empty installation never asks for confirmation.
(
    INSTALL_OPT="$INSTALL_ROOT/fresh-force"
    mkdir -p "$INSTALL_OPT"
    : > "$INSTALL_ROOT/answer"
    : > "$INSTALL_ROOT/prompt"
    installer_env --force > "$INSTALL_ROOT/fresh-force-output"
    assert_empty "$INSTALL_ROOT/prompt" "подтверждение --force на чистой системе"
)
pass "--force работает и на чистой системе без вопроса"

# Regression: TERM between down/up must attempt up and stop execution.
new_case
load_config "$MANAGER_ROOT/config/Wireguard0.conf"
FAILURE_THRESHOLD=1
write_config
signal_result=0
run_watchdog terminate_during_restart 15000 --force > "$CASE_DIR/result" || signal_result=$?
assert_equal "$signal_result" 143 "код завершения TERM"
assert_contains "$MOCK_DIR/ndmc.log" 'interface Wireguard0 down' "выключение до TERM"
assert_contains "$MOCK_DIR/ndmc.log" 'interface Wireguard0 up' "аварийное включение после TERM"
assert_equal "$(wc -l < "$MOCK_DIR/sleep.log" | tr -d ' ')" 1 "отсутствие продолжения после TERM"
[ ! -d "$RUN_DIR/wg-watchdog-Wireguard0.lock" ] || fail "блокировка осталась после TERM"
pass "TERM завершает watchdog и пытается вернуть интерфейс в up"

# A live manager lock excludes another manager; dead known owners can recover.
(
    RUN_DIR="$TEST_ROOT/manager-locks"
    acquire_manager_lock || fail "первый менеджер не получил блокировку"
    if acquire_manager_lock; then fail "второй менеджер получил живую блокировку"; fi
    printf '99999999\n' > "$RUN_DIR/manager.lock/pid"
    acquire_manager_lock || fail "блокировка завершённого менеджера не восстановлена"
    MANAGER_LOCK_HELD=yes
    release_manager_lock
    [ ! -d "$RUN_DIR/manager.lock" ] || fail "блокировка менеджера не освобождена"
)
pass "блокировка исключает второго менеджера и восстанавливается после известного мёртвого PID"

# Maintenance timeout must preserve a live worker lock and all settings.
(
    RUN_DIR="$TEST_ROOT/maintenance-live"
    mkdir -p "$RUN_DIR/wg-watchdog-Wireguard0.lock"
    printf '%s\n' "$$" > "$RUN_DIR/wg-watchdog-Wireguard0.lock/pid"
    WAIT_SECONDS=0
    if begin_maintenance >/dev/null; then fail "обслуживание разрешено при живом процессе"; fi
    [ -f "$RUN_DIR/wg-watchdog-Wireguard0.lock/pid" ] || fail "живая блокировка удалена"
    [ ! -d "$RUN_DIR/maintenance.lock" ] || fail "барьер остался после отказа"
)
pass "обслуживание не удаляет блокировку живого процесса"

# Maintenance barrier suppresses new worker activity and logging.
new_case
load_config "$MANAGER_ROOT/config/Wireguard0.conf"
write_config
mkdir "$RUN_DIR/maintenance.lock"
run_watchdog tunnel_down 16000 --force > /dev/null
assert_empty "$MOCK_DIR/ping.log" "ping во время обслуживания"
assert_empty "$MOCK_DIR/ndmc.log" "ndmc во время обслуживания"
rmdir "$RUN_DIR/maintenance.lock"
pass "новые проверки не запускаются во время обслуживания"

# An incomplete lock must not be mistaken for an abandoned lock.
mkdir "$RUN_DIR/wg-watchdog-Wireguard0.lock"
run_watchdog tunnel_down 16000 --force > /dev/null
[ -d "$RUN_DIR/wg-watchdog-Wireguard0.lock" ] || fail "незавершённая блокировка захвачена другим процессом"
assert_empty "$MOCK_DIR/ndmc.log" "перезапуск при незавершённой блокировке"
rmdir "$RUN_DIR/wg-watchdog-Wireguard0.lock"
pass "отсутствие PID не разрешает захват чужой блокировки"

# A delayed cron command after uninstall must exit without reading a config.
: > "$RUN_DIR/uninstalled"
rm -f "$CONFIG_DIR/Wireguard0.conf"
run_watchdog tunnel_down 16000 --force > /dev/null
assert_empty "$MOCK_DIR/logger.log" "ошибка конфигурации после удаления"
pass "отложенный cron тихо завершается после удаления"

# Direct uninstall must bypass package installation and work without opkg.
(
    direct_root="$TEST_ROOT/direct-uninstall"
    mkdir -p "$direct_root/opt/bin" "$direct_root/opt/etc/wg-watchdog.d" "$direct_root/run"
    cp "$WATCHDOG" "$direct_root/opt/bin/wg-watchdog.sh"
    cp "$MANAGER" "$direct_root/opt/bin/wg-watchdog-manager"
    printf '%s\n' '17 * * * * root /opt/bin/foreign-task' > "$direct_root/opt/etc/crontab"
    printf '2\nyes\n' > "$direct_root/input"
    : > "$direct_root/output"
    WG_WATCHDOG_LIB_ONLY=no \
    WG_WATCHDOG_OPT_ROOT="$direct_root/opt" \
    WG_WATCHDOG_RUN_DIR="$direct_root/run" \
    WG_WATCHDOG_STATE_DIR="$direct_root/run" \
    WG_WATCHDOG_INPUT="$direct_root/input" \
    WG_WATCHDOG_OUTPUT="$direct_root/output" \
        sh "$MANAGER" --uninstall > "$direct_root/result"
    [ ! -e "$direct_root/opt/bin/wg-watchdog-manager" ] || fail "прямое удаление не удалило менеджер"
    assert_contains "$direct_root/result" 'WG Watchdog и все его задания удалены' "результат прямого удаления"
    assert_contains "$direct_root/opt/etc/crontab" 'foreign-task' "чужой cron"
)
pass "прямое удаление работает без opkg и установки зависимостей"

# Cancel an uninstall with a live worker before touching cron or program files.
(
    TMP_FILES=""
    trap cleanup EXIT
    prepare_dialog_case blocked-uninstall
    WATCHDOG_PATH="$DIALOG_ROOT/watchdog"
    MANAGER_PATH="$DIALOG_ROOT/manager"
    : > "$WATCHDOG_PATH"
    : > "$MANAGER_PATH"
    printf 'foreign cron\n' > "$CRONTAB_PATH"
    mkdir -p "$RUN_DIR/wg-watchdog-Wireguard0.lock"
    printf '%s\n' "$$" > "$RUN_DIR/wg-watchdog-Wireguard0.lock/pid"
    printf '2\nyes\n' > "$INPUT_DEVICE"
    open_console
    WAIT_SECONDS=0
    uninstall_program > "$DIALOG_ROOT/result"
    [ -e "$MANAGER_PATH" ] && [ -e "$WATCHDOG_PATH" ] || fail "удалены файлы живого задания"
    assert_contains "$CRONTAB_PATH" 'foreign cron' "cron при отказе удаления"
    assert_contains "$DIALOG_ROOT/result" 'Изменения отменены' "отказ удаления занятого задания"
)
pass "удаление при живом задании сохраняет cron и программу"

# End of an active worker during the bounded wait permits maintenance.
(
    RUN_DIR="$TEST_ROOT/maintenance-finishes"
    mkdir -p "$RUN_DIR/wg-watchdog-Wireguard0.lock"
    printf '%s\n' "$$" > "$RUN_DIR/wg-watchdog-Wireguard0.lock/pid"
    WAIT_SECONDS=1
    simulated_finish() {
        rm -f "$RUN_DIR/wg-watchdog-Wireguard0.lock/pid"
        rmdir "$RUN_DIR/wg-watchdog-Wireguard0.lock"
    }
    SLEEP_BIN=simulated_finish
    begin_maintenance > /dev/null || fail "обслуживание не дождалось завершения"
    [ -d "$RUN_DIR/maintenance.lock" ] || fail "барьер снят слишком рано"
    end_maintenance
)
pass "обслуживание продолжает работу после завершения активного задания"

# A failed file removal must not be reported as success.
(
    prepare_dialog_case failed-uninstall
    WATCHDOG_PATH="$DIALOG_ROOT/watchdog"
    MANAGER_PATH="$DIALOG_ROOT/manager"
    LEGACY_CONFIG="$DIALOG_ROOT/legacy"
    SHORT_COMMAND="$DIALOG_ROOT/wgwm"
    : > "$WATCHDOG_PATH"
    : > "$MANAGER_PATH"
    printf '2\nyes\n' > "$INPUT_DEVICE"
    open_console
    rm() {
        for remove_arg in "$@"; do
            [ "$remove_arg" != "$WATCHDOG_PATH" ] || return 1
        done
        command rm "$@"
    }
    if (trap finish EXIT; uninstall_program) > "$DIALOG_ROOT/output" 2>&1; then
        fail "ошибка удаления скрыта"
    fi
    assert_contains "$DIALOG_ROOT/output" 'удаление не завершено' "частичное удаление"
    if grep -F 'WG Watchdog удалён.' "$DIALOG_ROOT/output" >/dev/null; then fail "ложный успех удаления"; fi
)
pass "ошибка удаления файла явно отмечается как незавершённое удаление"

# Directory symlinks cannot redirect uninstall to someone else's files.
(
    protected_root="$TEST_ROOT/protected-directory"
    mkdir -p "$protected_root/foreign"
    ln -s "$protected_root/foreign" "$protected_root/config"
    CONFIG_DIR="$protected_root/config"
    if (check_managed_directories) > /dev/null 2>&1; then fail "принят каталог-ссылка"; fi
)
pass "каталоги-ссылки отклоняются до удаления"

# Keenetic BusyBox stat is built without -c; ls -ldn is available.
(
    mapped_root="$TEST_ROOT/mapped-owner"
    mkdir -p "$mapped_root/opt/bin" "$mapped_root/opt/etc/wg-watchdog.d"
    OPT_ROOT="$mapped_root/opt"
    MANAGER_PATH="$mapped_root/opt/bin/wg-watchdog-manager"
    : > "$MANAGER_PATH"
    CONFIG_DIR="$mapped_root/opt/etc/wg-watchdog.d"
    STATE_DIR="$mapped_root/missing-state"
    RUN_DIR="$mapped_root/missing-run"
    owner_file="$mapped_root/stat-called"
    stat() {
        : > "$owner_file"
        printf "stat: invalid option -- 'c'\n" >&2
        return 1
    }
    check_managed_directories
    [ ! -e "$owner_file" ] || fail "проверка зависит от stat"
    chmod 775 "$CONFIG_DIR"
    if (check_managed_directories) > /dev/null 2>&1; then
        fail "приняты права записи группы"
    fi
    chmod 757 "$CONFIG_DIR"
    if (check_managed_directories) > /dev/null 2>&1; then
        fail "приняты права записи остальных"
    fi
    chmod 755 "$CONFIG_DIR"
    ls() { printf 'drwxr-xr-x 2 1234 0 232 Sep 9 11:51 %s\n' "$CONFIG_DIR"; }
    if (check_managed_directories) > /dev/null 2>&1; then
        fail "принят посторонний владелец каталога конфигурации"
    fi
    ls() { printf 'unrecognized output\n'; }
    if (check_managed_directories) > /dev/null 2>&1; then fail "приняты неверные метаданные"; fi
    ls() { return 1; }
    if (check_managed_directories) > /dev/null 2>&1; then fail "скрыта ошибка ls"; fi
)
pass "проверка прав работает без stat -c и отклоняет небезопасные каталоги"

prepare_update_case() {
    update_name=$1
    UPDATE_CASE_ROOT="$TEST_ROOT/$update_name"
    OPT_ROOT="$UPDATE_CASE_ROOT/opt"
    WATCHDOG_PATH="$OPT_ROOT/bin/wg-watchdog.sh"
    MANAGER_PATH="$OPT_ROOT/bin/wg-watchdog-manager"
    UPDATE_DIR="$OPT_ROOT/bin/.wg-watchdog-update"
    RUN_DIR="$UPDATE_CASE_ROOT/run"
    TMP_DIR="$UPDATE_CASE_ROOT/tmp"
    DF_BIN="$UPDATE_CASE_ROOT/df"
    SYNC_BIN=/bin/true
    SHA256_BIN=sha256sum
    mkdir -p "$OPT_ROOT/bin" "$RUN_DIR" "$TMP_DIR"
    cp "$WATCHDOG" "$WATCHDOG_PATH"
    cp "$MANAGER" "$MANAGER_PATH"
    cp "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected"
    cp "$MANAGER_PATH" "$UPDATE_CASE_ROOT/manager.expected"
    sed 's/^VERSION="[^"]*"/VERSION="9.9.9"/' "$WATCHDOG" > "$UPDATE_CASE_ROOT/watchdog.new"
    sed 's/^VERSION="[^"]*"/VERSION="9.9.9"/' "$MANAGER" > "$UPDATE_CASE_ROOT/manager.new"
    cat > "$DF_BIN" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'mock 999999 0 999999 0%% /\n'
EOF
    chmod 755 "$DF_BIN" "$WATCHDOG_PATH" "$MANAGER_PATH"
    MAINTENANCE_HELD=no
}

# Successful update leaves only the two new live files and no flash cache.
(
    prepare_update_case update-success
    transactional_install "$UPDATE_CASE_ROOT/watchdog.new" "$UPDATE_CASE_ROOT/manager.new" 9.9.9
    assert_contains "$WATCHDOG_PATH" 'VERSION="9.9.9"' "новый watchdog"
    assert_contains "$MANAGER_PATH" 'VERSION="9.9.9"' "новый менеджер"
    [ ! -e "$UPDATE_DIR" ] || fail "каталог транзакции остался после успеха"
)
pass "транзакционное обновление заменяет согласованную пару и очищает временные файлы"

# Failure of the second replacement restores both original scripts.
(
    prepare_update_case update-second-move-fails
    mv() {
        if [ "$1" = "$UPDATE_DIR/manager.new" ] && [ "$2" = "$MANAGER_PATH" ]; then return 1; fi
        command mv "$@"
    }
    if transactional_install "$UPDATE_CASE_ROOT/watchdog.new" "$UPDATE_CASE_ROOT/manager.new" 9.9.9 >/dev/null; then
        fail "ошибка второй замены скрыта"
    fi
    cmp -s "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected" || fail "watchdog не восстановлен"
    cmp -s "$MANAGER_PATH" "$UPDATE_CASE_ROOT/manager.expected" || fail "менеджер не восстановлен"
    [ ! -e "$UPDATE_DIR" ] || fail "транзакция осталась после успешного отката"
)
pass "ошибка замены менеджера откатывает оба файла"

# A durable marker from an interrupted update is recovered on the next start.
(
    prepare_update_case update-power-loss
    mkdir "$UPDATE_DIR"
    cp "$WATCHDOG_PATH" "$UPDATE_DIR/watchdog.old"
    cp "$MANAGER_PATH" "$UPDATE_DIR/manager.old"
    cp "$UPDATE_CASE_ROOT/watchdog.new" "$WATCHDOG_PATH"
    printf 'watchdog-installed\n' > "$UPDATE_DIR/state"
    recover_interrupted_update >/dev/null
    cmp -s "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected" || fail "watchdog не восстановлен после обрыва"
    cmp -s "$MANAGER_PATH" "$UPDATE_CASE_ROOT/manager.expected" || fail "менеджер изменён при восстановлении"
    [ ! -e "$UPDATE_DIR" ] || fail "маркер обрыва не очищен"
)
pass "незавершённое обновление восстанавливается при следующем запуске"

# A committed update only needs cleanup; the new pair must remain active.
(
    prepare_update_case update-committed-cleanup
    mkdir "$UPDATE_DIR"
    cp "$WATCHDOG_PATH" "$UPDATE_DIR/watchdog.old"
    cp "$MANAGER_PATH" "$UPDATE_DIR/manager.old"
    cp "$UPDATE_CASE_ROOT/watchdog.new" "$WATCHDOG_PATH"
    cp "$UPDATE_CASE_ROOT/manager.new" "$MANAGER_PATH"
    printf 'committed\n' > "$UPDATE_DIR/state"
    recover_interrupted_update >/dev/null
    assert_contains "$WATCHDOG_PATH" 'VERSION="9.9.9"' "watchdog после committed"
    assert_contains "$MANAGER_PATH" 'VERSION="9.9.9"' "менеджер после committed"
    [ ! -e "$UPDATE_DIR" ] || fail "завершённая транзакция не очищена"
)
pass "подтверждённое обновление сохраняется, а остатки транзакции очищаются"

# Unknown state is never guessed: recovery stops without touching live files.
(
    prepare_update_case update-unknown-state
    mkdir "$UPDATE_DIR"
    cp "$WATCHDOG_PATH" "$UPDATE_DIR/watchdog.old"
    cp "$MANAGER_PATH" "$UPDATE_DIR/manager.old"
    printf 'unexpected-state\n' > "$UPDATE_DIR/state"
    if recover_interrupted_update >/dev/null 2>&1; then fail "неизвестное состояние принято"; fi
    cmp -s "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected" || fail "watchdog изменён при неизвестном состоянии"
    cmp -s "$MANAGER_PATH" "$UPDATE_CASE_ROOT/manager.expected" || fail "менеджер изменён при неизвестном состоянии"
    [ -d "$UPDATE_DIR" ] || fail "диагностические данные неизвестной транзакции удалены"
)
pass "неизвестное состояние транзакции останавливает восстановление без догадок"

# The free-space gate runs before any update data is written to /opt.
(
    prepare_update_case update-no-space
    cat > "$DF_BIN" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'mock 1 1 0 100%% /\n'
EOF
    chmod 755 "$DF_BIN"
    if transactional_install "$UPDATE_CASE_ROOT/watchdog.new" "$UPDATE_CASE_ROOT/manager.new" 9.9.9 >/dev/null; then
        fail "обновление началось без свободного места"
    fi
    [ ! -e "$UPDATE_DIR" ] || fail "при нехватке места создан каталог транзакции"
    cmp -s "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected" || fail "watchdog изменён без места"
)
pass "нехватка места обнаруживается до записей транзакции"

# A downloaded file with the wrong digest is rejected before maintenance and replacement.
(
    prepare_update_case update-bad-hash
    RAW_REPOSITORY_URL=https://example.invalid
    REMOTE_COMMIT=0123456789abcdef0123456789abcdef01234567
    REMOTE_VERSION=9.9.9
    REMOTE_WATCHDOG_SHA256=0000000000000000000000000000000000000000000000000000000000000000
    sha256_file "$UPDATE_CASE_ROOT/manager.new"
    REMOTE_MANAGER_SHA256=$REPLY
    download_file() {
        case "$1" in
            */wg-watchdog.sh) cp "$UPDATE_CASE_ROOT/watchdog.new" "$2" ;;
            */wg-watchdog-manager.sh) cp "$UPDATE_CASE_ROOT/manager.new" "$2" ;;
            *) return 1 ;;
        esac
    }
    if (install_program_files) > "$UPDATE_CASE_ROOT/result" 2>&1; then fail "неверный SHA-256 принят"; fi
    assert_contains "$UPDATE_CASE_ROOT/result" 'SHA-256 watchdog не совпадает' "диагностика хеша"
    [ ! -e "$UPDATE_DIR" ] || fail "при неверном хеше создана транзакция"
    cmp -s "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected" || fail "watchdog изменён при неверном хеше"
)
pass "несовпадение SHA-256 отклоняется до замены файлов"

# An interrupted download is rejected while the installed pair remains untouched.
(
    prepare_update_case update-download-fails
    RAW_REPOSITORY_URL=https://example.invalid
    REMOTE_COMMIT=0123456789abcdef0123456789abcdef01234567
    REMOTE_VERSION=9.9.9
    sha256_file "$UPDATE_CASE_ROOT/watchdog.new"
    REMOTE_WATCHDOG_SHA256=$REPLY
    sha256_file "$UPDATE_CASE_ROOT/manager.new"
    REMOTE_MANAGER_SHA256=$REPLY
    download_file() {
        case "$1" in
            */wg-watchdog.sh) cp "$UPDATE_CASE_ROOT/watchdog.new" "$2" ;;
            */wg-watchdog-manager.sh) printf '#!/bin/sh\n' > "$2"; return 1 ;;
            *) return 1 ;;
        esac
    }
    if (install_program_files) > "$UPDATE_CASE_ROOT/result" 2>&1; then fail "обрыв загрузки скрыт"; fi
    assert_contains "$UPDATE_CASE_ROOT/result" 'не удалось загрузить менеджер' "диагностика обрыва загрузки"
    [ ! -e "$UPDATE_DIR" ] || fail "при обрыве загрузки создана транзакция"
    cmp -s "$WATCHDOG_PATH" "$UPDATE_CASE_ROOT/watchdog.expected" || fail "watchdog изменён при обрыве загрузки"
    cmp -s "$MANAGER_PATH" "$UPDATE_CASE_ROOT/manager.expected" || fail "менеджер изменён при обрыве загрузки"
)
pass "обрыв загрузки не затрагивает установленную пару файлов"

printf '\nВсе тесты пройдены: %s\n' "$PASS_COUNT"
