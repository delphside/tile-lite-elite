"""The fake profiles the tests read instead of Tile Lite Elite's (#485 stage 2).

Three files stand in for the three the tooling reads: a technical profile, a
programme file, and a programme profile in a fake live checkout. They are for a
fake application, `widget`, whose values differ from the real one's wherever a
test could otherwise pass by reading a built-in value.

`use_fakes()` points the loader at them through the same variables a person or
CI would use. The test packages call it on import, so every test in a run reads
the fakes unless it sets its own.
"""

from __future__ import annotations

import contextlib
import os
import shutil
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
TECHNICAL = FIXTURES / "programme.toml"
OTHER_TECHNICAL = FIXTURES / "programme-other.toml"
CONFIG = FIXTURES / "programme-config.toml"
LIVE = FIXTURES / "live"
APPLICATION = "widget"
REPOSITORY = "fakeorg/widget"


def use_fakes() -> None:
    os.environ["PROGRAMME_PROFILE"] = str(TECHNICAL)
    os.environ["PROGRAMME_CONFIG"] = str(CONFIG)
    os.environ["PROGRAMME_DIR"] = str(LIVE)


def install_profile(live: Path) -> Path:
    """Put the fake application's folder, with its programme profile, in `live`."""
    target = live / "applications" / APPLICATION
    shutil.copytree(LIVE / "applications" / APPLICATION, target, dirs_exist_ok=True)
    return target


@contextlib.contextmanager
def using(technical: Path | None = None, config: Path | None = None):
    """Read another technical profile (or programme file) for a while."""
    saved = {k: os.environ.get(k) for k in ("PROGRAMME_PROFILE", "PROGRAMME_CONFIG")}
    if technical:
        os.environ["PROGRAMME_PROFILE"] = str(technical)
    if config:
        os.environ["PROGRAMME_CONFIG"] = str(config)
    try:
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


@contextlib.contextmanager
def inside(path: Path):
    """Work from this directory, as a script run there would."""
    before = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(before)
