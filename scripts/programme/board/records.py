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
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# **The one constant.** Relative to the *main worktree's* root, so a script run
# from a linked worktree (`.claude/worktrees/...`) finds the same live checkout
# as one run from the main checkout; `PROGRAMME_DIR` replaces it.
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


def main_worktree(root: Path) -> Path:
    """The root of the repository's main worktree: the parent of the common git
    directory, which every linked worktree shares. `root` itself when git cannot
    say (not a repository, no git)."""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return root
    common = out.stdout.strip()
    if out.returncode != 0 or not common:
        return root
    return Path(common).parent


def live(root: Path | None = None) -> Path:
    """The live checkout, for records. Exits non-zero with the path it tried."""
    base = main_worktree(root or ROOT)
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


def _git(path: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, timeout=10)


def problem(root: Path | None = None) -> str | None:
    """What is wrong with the live checkout for a session starting now, as one
    line naming the path, or None when it is present and HEAD contains the local
    `origin/main`.

    The branch does not matter: a cloud session puts every repository on a
    `claude/...` session branch and a record reaches main there by a short-lived
    pull request. A detached HEAD is judged the same way.

    Read-only and offline: it compares with the local `origin/main` ref and says
    it cannot tell when that ref is absent, because a fetch is a network call
    at the start of every session. It never changes the checkout.
    """
    try:
        path = live(root)
    except NoLiveCheckout as gone:
        return (f"The programme's live checkout is missing at {gone.tried}: clone "
                f"delphside/programme there, or set {ENV}; records cannot be read or written.")
    try:
        branch = _git(path, "rev-parse", "--abbrev-ref", "HEAD")
        if branch.returncode != 0:
            return f"The programme's live checkout at {path} is not a git checkout; records may be stale."
        if _git(path, "rev-parse", "--verify", "-q", "refs/remotes/origin/main").returncode != 0:
            return (f"The programme's live checkout at {path}: cannot tell whether it is "
                    f"behind origin/main (no local origin/main ref; git fetch there).")
        behind = _git(path, "rev-list", "--count", "HEAD..refs/remotes/origin/main").stdout.strip()
        if behind not in ("", "0"):
            return (f"The programme's live checkout at {path} is {behind} commit(s) behind "
                    f"origin/main (as last fetched); pull it before reading records.")
    except (OSError, subprocess.SubprocessError):
        return f"The programme's live checkout at {path}: cannot tell its state (git did not answer)."
    return None
