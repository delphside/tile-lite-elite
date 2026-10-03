"""Running one of the tooling's commands, such as `board-*.py`, as a caller would."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[3]


def run(command: str, *args: str, stdin: str = "", cwd: Path | None = None,
        env: dict | None = None) -> subprocess.CompletedProcess:
    """`python3 scripts/<command> args...`, capturing its output as text.

    `command` is the path below `scripts/`, e.g. `programme/board/board-refs.py`."""
    return subprocess.run(
        [sys.executable, str(SCRIPTS / command), *args],
        input=stdin, capture_output=True, text=True, cwd=cwd or SCRIPTS, env=env,
    )
