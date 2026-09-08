#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WATCHDOG="$REPO_DIR/wg-watchdog.sh"
INSTALLER="$REPO_DIR/install.sh"
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
    grep -F "$2" "$1" >/dev/null 2>&1 || fail "$3: в $1 нет '$2'"
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
    cat > "$CONFIG_DIR/Wireguard0.conf" <<EOF
JOB_ID='Wireguard0'
WG_INTERFACE='Wireguard0'
WG_SERVER_TUNNEL_IP='$tunnel'
WG_SERVER_PUBLIC_IP='$public'
PING_COUNT='3'
PING_TIMEOUT='3'
RESTART_DELAY='3'
CHECK_INTERVAL='5'
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
printf '100.00 0.00\n' > "$CASE_DIR/uptime"
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
run_watchdog tunnel_down 4060 --force >/dev/null
load_test_state
assert_contains "$STATE_DIR/Wireguard0.state" "LAST_RESULT='cooldown" "состояние cooldown"
assert_empty "$MOCK_DIR/ndmc.log" "cooldown должен блокировать повторный restart"
pass "cooldown ограничивает повторные перезапуски"

# После завершения cooldown перезапуск снова разрешён.
: > "$MOCK_DIR/ndmc.log"
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
run_watchdog internet_down 5600 --force >/dev/null
internet_log_count=$(grep -c 'интернет недоступен' "$MOCK_DIR/logger.log" || true)
assert_equal "$internet_log_count" 1 "подавление повторного логирования"
pass "повторяющееся состояние не засоряет системный журнал"

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

# Чистые функции менеджера: интервалы и cron-выражения.
WG_WATCHDOG_LIB_ONLY=yes
export WG_WATCHDOG_LIB_ONLY
# shellcheck disable=SC1090
. "$INSTALLER"
trap cleanup_tests EXIT HUP INT TERM
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
pass "конфигурация v1.1 автоматически обновляется до v1.2"

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

printf '\nВсе тесты пройдены: %s\n' "$PASS_COUNT"
