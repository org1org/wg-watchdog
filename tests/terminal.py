#!/usr/bin/env python3
"""PTY integration checks; standard library only, never installed on a router."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

REPO = Path(__file__).resolve().parent.parent


def run_case(rows=24, cols=80, terminate=False, plain=False, jobs=0,
             actions=None, job_answers=None, disabled_jobs=None,
             update_available=False, wizard_answers=None):
    with tempfile.TemporaryDirectory(prefix="wgwm-pty-") as root:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(os.environ, TERM="xterm", WG_WATCHDOG_LIB_ONLY="yes",
                   TEST_ROOT=root, TEST_REPO=str(REPO), TEST_PLAIN=str(int(plain)))
        env["TEST_UPDATE_AVAILABLE"] = str(int(update_available))
        env["MOCK_DIR"] = root
        env["MOCK_SCENARIO"] = "healthy"
        env.pop("NO_COLOR", None)
        Path(root, "config").mkdir()
        for number in range(jobs):
            enabled = "no" if number in (disabled_jobs or []) else "yes"
            Path(root, "config", f"Wireguard{number}.conf").write_text(
                f"JOB_ID='Wireguard{number}'\nWG_INTERFACE='Wireguard{number}'\n"
                f"ENABLED='{enabled}'\nWG_SERVER_TUNNEL_IP='10.0.0.1'\nCHECK_INTERVAL='5'\n"
            )
        script = """
            . "$TEST_REPO/wg-watchdog-manager.sh"
            CONFIG_DIR="$TEST_ROOT/config"
            RUN_DIR="$TEST_ROOT/run"
            STATE_DIR="$TEST_ROOT/run"
            TMP_DIR="$TEST_ROOT"
            CRONTAB_PATH="$TEST_ROOT/crontab"
            CRON_INIT=/bin/true
            PIDOF_BIN=/bin/true
            PING_BIN="$TEST_REPO/tests/mocks/ping"
            WATCHDOG_PATH=/opt/bin/wg-watchdog.sh
            mkdir -p "$CONFIG_DIR" "$RUN_DIR"
            NDMC_BIN="$TEST_REPO/tests/mocks/ndmc-config"
            INPUT_DEVICE=/dev/stdin
            OUTPUT_DEVICE=/dev/stdout
            open_console
            acquire_manager_lock || exit 1
            MANAGER_LOCK_HELD=yes
            [ "$TEST_PLAIN" = 1 ] || ui_start
            if [ "$TEST_UPDATE_AVAILABLE" = 1 ]; then
                UPDATE_AVAILABLE=yes
                REMOTE_VERSION=9.9.9
            fi
            main_menu
        """
        process = subprocess.Popen(["sh", "-c", script], env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        sent = False
        main_prompts_answered = 0
        action_prompts_answered = 0
        pages_answered = 0
        wizard_prompts_answered = 0
        pending_main_answers = list(actions or ["0"])
        pending_action_answers = list(job_answers or [])
        pending_wizard_answers = list(wizard_answers or [])
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                    main_prompts_seen = output.count(
                        "Выберите интерфейс".encode()
                    )
                    action_prompts_seen = output.count("Выберите действие".encode())
                    pages_seen = output.count("Нажмите Enter, чтобы продолжить".encode())
                    wizard_prompts_seen = sum(output.count(prompt.encode()) for prompt in [
                        "Введите внутренний IP-адрес WireGuard-сервера",
                        "Использовать проверку публичного адреса?",
                    ])
                    if wizard_prompts_seen > wizard_prompts_answered:
                        wizard_prompts_answered = wizard_prompts_seen
                        os.write(master, (pending_wizard_answers.pop(0) + "\n").encode())
                    elif action_prompts_seen > action_prompts_answered:
                        action_prompts_answered = action_prompts_seen
                        os.write(master, (pending_action_answers.pop(0) + "\n").encode())
                    elif main_prompts_seen > main_prompts_answered:
                        main_prompts_answered = main_prompts_seen
                        if terminate:
                            process.send_signal(signal.SIGTERM)
                        else:
                            os.write(master, (pending_main_answers.pop(0) + "\n").encode())
                        sent = True
                    elif pages_seen > pages_answered:
                        pages_answered = pages_seen
                        os.write(master, b"\n")
                if process.poll() is not None and not ready:
                    break
            if process.poll() is None:
                raise AssertionError(output.decode(errors="replace"))
            process.wait(timeout=2)
            assert sent, output.decode(errors="replace")
            assert process.returncode == (143 if terminate else 0), output
            assert not Path(root, "run", "manager.lock").exists()
            if plain:
                assert b"\x1b[?1049h" not in output
            else:
                assert b"\x1b[?1049h" in output
                assert b"\x1b[?1049l" in output
                assert b"\x1b[?7h" in output
                assert b"\x1b[2J" in output
                assert b"\x1b[1;36m" in output
                centered_title = re.search(
                    rb"\x1b\[\d+;1H\x1b\[2K( *)\x1b\[1;36mWG Watchdog Manager",
                    output,
                )
                assert centered_title, "Название в шапке не найдено"
                assert len(centered_title.group(1)) == (cols - len("WG Watchdog Manager")) // 2, \
                    "Название не отцентрировано"
                subtitle = "WireGuard recovery | v1.0.1 | org1org"
                centered_subtitle = re.search(
                    rb"\x1b\[\d+;1H\x1b\[2K( *)\x1b\[1;36m" + subtitle.encode(),
                    output,
                )
                assert centered_subtitle, "Подпись в шапке не найдена"
                assert len(centered_subtitle.group(1)) == (cols - len(subtitle)) // 2, \
                    "Подпись не отцентрирована"
            assert "Wireguard3".encode() in output, "Показаны не все интерфейсы"
            assert "Два пира".encode() in output, "Не показано описание последнего интерфейса"
            if job_answers:
                assert "Интерфейс: Wireguard".encode() in output
                assert "0) Назад".encode() in output
                assert "Какое задание".encode() not in output
            if disabled_jobs:
                assert b"\x1b[1;31m" in output, "Отключённое задание не выделено красным"
            if update_available:
                green_update = re.compile(
                    rb"\x1b\[1;32m\s*\d+\)\s+" +
                    "Обновить программу до версии 9.9.9".encode()
                )
                assert green_update.search(output), \
                    "Доступное обновление не выделено зелёным"
            if wizard_answers is not None:
                decoded = output.decode(errors="replace")
                start = decoded.index("Выбран внутренний адрес: 10.0.0.1.")
                finish = decoded.index("Использовать проверку публичного адреса?", start)
                wizard_section = decoded[start:finish]
                assert "\x1b[2J" not in wizard_section, \
                    "Экран очищен между шагами мастера"
                assert "Enter — использовать найденный адрес 10.0.0.1." in decoded
                assert "Enter — не включать проверку публичного адреса." in decoded
            return output.decode(errors="replace")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


if __name__ == "__main__":
    for case in [
        dict(rows=24, cols=80),
        dict(rows=20, cols=60),
        dict(terminate=True),
        dict(plain=True),
        dict(jobs=7, disabled_jobs=[2]),
        dict(jobs=2, actions=["3", "0"], job_answers=["0"]),
        dict(update_available=True),
        dict(actions=["1", "0"], job_answers=["1", "0"],
             wizard_answers=["", ""]),
    ]:
        run_case(**case)
        print("ok PTY", case)
