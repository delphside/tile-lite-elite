"""The facts that live in git and in the running environments.

`sources.py` talks to GitHub; this talks to the checkout and to `/health`.
Both feed the same model, because *where is this change* is answered by
commits and *what is live* by the machines, and neither is on the board.

**Everything here is derived, nothing is recorded.** A change's state comes
from whether a `Refs #N` commit exists and where it sits, so there is no field
to keep up to date and nothing that can drift. The cost is that the view is
only as good as the convention: a change with neither a `Refs #N` trailer nor
an `<N>-*` branch reads as not started. That is deliberate — papering over a
missing trailer would remove the one signal that the convention had slipped.
"""

from __future__ import annotations

import json
import re
import subprocess
import urllib.error
import urllib.request
from dataclasses import dataclass, field

REFS = re.compile(r"\b(?:Refs|Closes|Fixes|Resolves)\s+#(\d+)", re.I)


def _git(*args: str) -> str:
    try:
        out = subprocess.run(["git", *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout if out.returncode == 0 else ""


@dataclass
class Commits:
    """Which commits name which issue, and which side of `origin/main` they sit."""

    on_main: dict[int, list[str]] = field(default_factory=dict)
    off_main: dict[int, list[str]] = field(default_factory=dict)
    unreleased: dict[int, list[str]] = field(default_factory=dict)
    released: dict[int, list[str]] = field(default_factory=dict)
    unreleased_total: int = 0
    last_tag: str | None = None

    def state_of(self, number: int, live_at_merge: bool) -> str:
        """Where this change is. One rule, used by every block of R3.

        `live_at_merge` is the Route's answer, not the type's: a Repository
        Change reaches its users the moment it merges, so *merged, awaiting
        release* would be wrong for it and it is simply live. Reading this
        from the type instead of the Route is what made nine closed changes
        pile up under "done, not yet released" when all of them were already
        out.
        """
        # Order matters, and it is newest-work-first. Asking "is it released"
        # before "is work happening" made an issue with old shipped commits
        # and a live branch read as `released`, which is the one state that
        # stops anybody looking at it again.
        if number in self.off_main:
            return "in progress"
        if number in self.unreleased:
            return "live" if live_at_merge else "merged, awaiting release"
        if number in self.released:
            return "released"
        return "not started"


def commits(main: str = "origin/main") -> Commits:
    got = Commits()

    def collect(rev: list[str]) -> dict[int, list[str]]:
        found: dict[int, list[str]] = {}
        text = _git("log", "--no-merges", "--format=%H%x1f%B%x1e", *rev)
        for entry in text.split("\x1e"):
            if "\x1f" not in entry:
                continue
            sha, body = entry.split("\x1f", 1)
            for number in {int(n) for n in REFS.findall(body)}:
                found.setdefault(number, []).append(sha.strip())
        return found

    tags = [t for t in _git("tag", "--list", "prod-*", "--sort=-creatordate").split() if t]
    got.last_tag = tags[0] if tags else None

    got.on_main = collect([main])
    got.off_main = collect(["--all", f"^{main}"])
    # Anything already in the last production tag is out, whatever the board
    # says. The board is a plan; the tag is what happened. What sits between
    # the tag and `main` is the other half, and the two must be asked
    # separately -- `released` walks all history reachable from the tag, so on
    # its own it cannot tell shipped-long-ago from shipped-and-since-changed.
    if got.last_tag:
        got.released = collect([got.last_tag])
        got.unreleased = collect([f"{got.last_tag}..{main}"])
    else:
        got.unreleased = got.on_main
        count = _git("rev-list", "--no-merges", "--count",
                     f"{got.last_tag}..{main}").strip()
        got.unreleased_total = int(count) if count.isdigit() else 0
    return got


def branches() -> dict[int, list[str]]:
    """`<N>-short-name` branches, the fallback for a branch with no commits yet."""
    out: dict[int, list[str]] = {}
    for line in _git("branch", "-r", "--format=%(refname:short)").splitlines():
        name = line.strip().removeprefix("origin/")
        m = re.match(r"(\d+)-", name)
        if m:
            out.setdefault(int(m.group(1)), []).append(name)
    return out


def behind_main(version: str | None, main: str = "origin/main") -> str:
    """How far behind `main` a running environment is, in **changes**.

    Merges are excluded and reported separately. Counting them made this
    disagree with the release preview, which has always used `--no-merges`:
    two numbers for the same range a few rows apart, and no way to tell from
    the report which was wrong.
    """
    if not version or "+" not in version:
        return ""
    sha = version.split("+", 1)[1]
    if not _git("rev-parse", "-q", "--verify", f"{sha}^{{commit}}").strip():
        return "unknown commit"
    changes = _git("rev-list", "--count", "--no-merges", f"{sha}..{main}").strip()
    merges = _git("rev-list", "--count", "--merges", f"{sha}..{main}").strip()
    if not changes:
        return ""
    suffix = f" (+{merges} merges)" if merges and merges != "0" else ""
    if changes == "0":
        return f"up to date with main{suffix}"
    return f"{changes} change{'' if changes == '1' else 's'} behind main{suffix}"


def live_version(url: str, timeout: float = 5.0) -> str | None:
    """`app_version` from `/health`, or None if the environment did not answer.

    None means *did not answer*, never *not deployed*: an unreachable host and
    an empty one are different facts and the report must not merge them.
    """
    try:
        with urllib.request.urlopen(f"{url}/health", timeout=timeout) as response:
            return (json.loads(response.read().decode()) or {}).get("app_version")
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return None
