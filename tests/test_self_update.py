"""copilot_self_update behavior — DEN-2982.

Copilot pins installed plugins, so the guard self-updates on sessionStart, throttled to once
per calendar day via ~/.bluebear-agentless/.plugin-update-day. These tests run the ACTUAL shell
lib with a fake `copilot` on PATH (records each invocation) and assert: it updates once, it
throttles same-day, it no-ops without `copilot`, and only the sessionStart hook triggers it.
"""
from __future__ import annotations

import os
import subprocess
import time
from datetime import date
from pathlib import Path

_AGENTLESS = Path(__file__).resolve().parents[1] / "plugins" / "bluebear-guard" / "agentless"
# The composed Copilot library: shared helpers + Copilot functions.
LIB = (_AGENTLESS / "shared.sh").read_text() + "\n" + (_AGENTLESS / "copilot.sh").read_text()


def _fake_copilot(bin_dir: Path, marker: Path) -> str:
    """A fake `copilot` that appends its args to `marker` — proves the update was invoked."""
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "copilot").write_text(f'#!/bin/sh\necho "$@" >> "{marker}"\nexit 0\n')
    (bin_dir / "copilot").chmod(0o755)
    return str(bin_dir)


def _run(snippet: str, home: Path, path_extra: str | None) -> None:
    env = {
        **os.environ,
        "BB_LIB": LIB,
        "HOME": str(home),
        "PATH": f"{path_extra}:{os.environ['PATH']}" if path_extra else "/usr/bin:/bin",
    }
    subprocess.run(["/bin/sh", "-c", f'eval "$BB_LIB"; {snippet}'], env=env, timeout=30, check=False)


def _marker_lines(marker: Path, wait_s: float = 3.0) -> list[str]:
    """Poll for the backgrounded update to write the marker."""
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if marker.exists() and marker.read_text().strip():
            break
        time.sleep(0.05)
    return marker.read_text().splitlines() if marker.exists() else []


def test_self_update_runs_once_and_records_day(tmp_path):
    home, marker = tmp_path / "home", tmp_path / "calls.txt"
    path_extra = _fake_copilot(tmp_path / "bin", marker)
    _run("copilot_self_update", home, path_extra)

    day_file = home / ".bluebear-agentless" / ".plugin-update-day"
    assert day_file.read_text().strip() == date.today().isoformat(), "attempt day not recorded"
    lines = _marker_lines(marker)
    assert lines == ["plugin update bluebear-guard@bluebear"], f"unexpected copilot calls: {lines}"


def test_self_update_throttled_same_day(tmp_path):
    home, marker = tmp_path / "home", tmp_path / "calls.txt"
    path_extra = _fake_copilot(tmp_path / "bin", marker)
    _run("copilot_self_update", home, path_extra)
    _marker_lines(marker)  # let the first (backgrounded) call land
    _run("copilot_self_update", home, path_extra)  # same day → must NOT run again
    time.sleep(0.5)
    assert len(marker.read_text().splitlines()) == 1, "throttle failed: copilot ran twice same day"


def test_self_update_noop_without_copilot(tmp_path):
    home = tmp_path / "home"
    _run("copilot_self_update", home, path_extra=None)  # no `copilot` on PATH
    assert not (home / ".bluebear-agentless" / ".plugin-update-day").exists(), (
        "should not record an attempt when copilot is unavailable"
    )


def test_only_session_start_triggers_update(tmp_path):
    home_pre = tmp_path / "home"
    day_file = home_pre / ".bluebear-agentless" / ".plugin-update-day"
    path_extra = _fake_copilot(tmp_path / "bin", tmp_path / "calls.txt")
    env_pre = {**os.environ, "BB_LIB": LIB, "HOME": str(home_pre), "PATH": f"{path_extra}:{os.environ['PATH']}"}

    # PreToolUse must NOT trigger a self-update.
    subprocess.run(
        ["/bin/sh", "-c", 'eval "$BB_LIB"; copilot_main PreToolUse'],
        input='{"sessionId":"s1","toolName":"bash","toolArgs":"{}","cwd":"/tmp"}',
        text=True, env=env_pre, timeout=30, check=False,
    )
    assert not day_file.exists(), "PreToolUse should not trigger self-update"

    # SessionStart MUST trigger it (records the attempt day synchronously).
    subprocess.run(
        ["/bin/sh", "-c", 'eval "$BB_LIB"; copilot_main SessionStart'],
        input='{"sessionId":"s1","cwd":"/tmp"}',
        text=True, env=env_pre, timeout=30, check=False,
    )
    assert day_file.read_text().strip() == date.today().isoformat(), "SessionStart did not self-update"


if __name__ == "__main__":
    import tempfile

    for _name, _fn in sorted((n, f) for n, f in globals().items() if n.startswith("test_")):
        with tempfile.TemporaryDirectory() as d:
            _fn(Path(d))
        print(f"PASS {_name}")
    print("all self-update checks passed")
