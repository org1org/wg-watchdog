#!/usr/bin/env python3
"""PTY integration checks; standard library only, never installed on a router."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

REPO = Path(__file__).resolve().parent.parent


def run_case(rows=24, cols=80, terminate=False, plain=False, jobs=0,
             actions=None, job_answers=None, disabled_jobs=None):
    with tempfile.TemporaryDirectory(prefix="wgwm-pty-") as root:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(os.environ, TERM="xterm", WG_WATCHDOG_LIB_ONLY="yes",
                   TEST_ROOT=root, TEST_REPO=str(REPO), TEST_PLAIN=str(int(plain)))
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
            mkdir -p "$CONFIG_DIR" "$RUN_DIR"
            NDMC_BIN="$TEST_REPO/tests/mocks/ndmc-config"
            INPUT_DEVICE=/dev/stdin
            OUTPUT_DEVICE=/dev/stdout
            open_console
            acquire_manager_lock || exit 1
            MANAGER_LOCK_HELD=yes
            [ "$TEST_PLAIN" = 1 ] || ui_start
            main_menu
        """
        process = subprocess.Popen(["sh", "-c", script], env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        sent = False
        prompts_answered = 0
        job_prompts_answered = 0
        pages_answered = 0
        pending_actions = list(actions or ["0"])
        pending_job_answers = list(job_answers or [])
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
                    prompts_seen = output.count("Выберите действие".encode())
                    job_prompts_seen = (
                        output.count("Выберите задание".encode())
                        + output.count("Какое задание".encode())
                    )
                    pages_seen = output.count("Enter — продолжить".encode())
                    if job_prompts_seen > job_prompts_answered:
                        job_prompts_answered = job_prompts_seen
                        os.write(master, (pending_job_answers.pop(0) + "\n").encode())
                    elif prompts_seen > prompts_answered:
                        prompts_answered = prompts_seen
                        if terminate:
                            process.send_signal(signal.SIGTERM)
                        else:
                            os.write(master, (pending_actions.pop(0) + "\n").encode())
                        sent = True
                    elif pages_seen > pages_answered:
                        pages_answered = pages_seen
                        os.write(master, b"\n")
                if process.poll() is not None and not ready:
                    break
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
            assert "Wireguard3".encode() in output, "Показаны не все интерфейсы"
            assert "Два пира".encode() in output, "Не показано описание последнего интерфейса"
            if job_answers:
                assert "Настроенные задания:".encode() in output
                assert "0) Вернуться в главное меню".encode() in output
                assert "Выберите задание [1]".encode() not in output
            if disabled_jobs:
                assert b"\x1b[1;31m" in output, "Отключённое задание не выделено красным"
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
    ]:
        run_case(**case)
        print("ok PTY", case)
