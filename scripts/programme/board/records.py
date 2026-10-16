"""Where the programme's files are, from this repository (#485 T4).

A session or a CI job has two copies of the programme repository, and they are
for different things:

- **The pinned submodule, `<repo>/programme/`,** holds what this application
  *uses*: the generic documents (the activity register, the templates, the
  rules). It is the commit this repository chose, so a change to the generic
  tooling reaches here only when the pin is moved. Read-only.
- **The live checkout beside the repository** holds what the programme
  *records*: the activity log, the weekly digests, this application's delivery
  log, artefact register, capacity plan and change documents. Records are
  read from and written to the head of the programme's main, never a pinned
  copy, because a record is true when it is written, not when a pin was
  taken. A script that needs it and does not find it stops and says where it
  looked; it never falls back to the pinned copy, which would read an old
  record and write a new one nowhere.

Stage 2 of #485 moves the default into an application profile; until then it is
`DEFAULT_PROGRAMME_DIR` below, and `PROGRAMME_DIR` overrides it (CI, tests).
Shell scripts ask `board-records.py live` rather than repeat the default.
"""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# **The one constant.** Relative to the repository root; `PROGRAMME_DIR` replaces it.
DEFAULT_PROGRAMME_DIR = "../programme"
ENV = "PROGRAMME_DIR"

# This application's folder in the programme repository.
APPLICATION = "tile-lite-elite"


class NoLiveCheckout(SystemExit):
    """The live checkout is not where it was looked for. Exits non-zero."""

    def __init__(self, tried: Path):
        super().__init__(
            f"cannot find the programme repository's live checkout at {tried}: "
            f"clone delphside/programme there, or set {ENV} to where it is "
            f"(the pinned copy in programme/ holds no current records, so it is not used)")
        self.tried = tried


def generic(root: Path | None = None) -> Path:
    """The pinned submodule: generic documents, read-only."""
    return (root or ROOT) / "programme"


def live(root: Path | None = None) -> Path:
    """The live checkout, for records. Exits non-zero with the path it tried."""
    base = root or ROOT
    given = os.environ.get(ENV)
    path = Path(given) if given else (base / DEFAULT_PROGRAMME_DIR)
    path = Path(os.path.normpath(path if path.is_absolute() else Path.cwd() / path))
    if not path.is_dir():
        raise NoLiveCheckout(path)
    return path


def application(root: Path | None = None) -> Path:
    """This application's records: `<live>/applications/tile-lite-elite`."""
    return live(root) / "applications" / APPLICATION


def activity_register() -> Path:
    return generic() / "docs" / "1.4-programme-activities.md"


def activity_log() -> Path:
    return live() / "records" / "2.3-activity-log.csv"


def weekly_digests() -> Path:
    return live() / "records" / "2.4-weekly-digest"


def capacity_plan() -> Path:
    return application() / "3.1.3-capacity-plan"


def change_documents() -> Path:
    return application() / "3.1.7-changes"
