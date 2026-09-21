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
from pathlib import Path

# **`Refs #N` does not imply anything specific; `Closes #N` does.** Owner,
# 2026-09-18. The convention (CLAUDE.md, docs/3.3 §393, docs/3.6 §1132) is that
# commits say `Refs #N` and **the deploy** is what closes them -- `Closes #N`
# is correct only where the change never leaves the repository, because
# nothing else will ever close it.
#
# So a `Refs` is evidence that work touched an issue and nothing more. Reading
# the two as the same thing made an incidental mention of #10 in an old commit
# report the Bot client harness as *released* while it sat at Scope, and then
# reported the contradiction as though the board were at fault.
CLOSES = re.compile(r"\b(?:Closes|Fixes|Resolves)\s+#(\d+)", re.I)
MENTIONS = re.compile(r"\bRefs\s+#(\d+)", re.I)


def _git(*args: str) -> str:
    try:
        out = subprocess.run(["git", *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout if out.returncode == 0 else ""


@dataclass
class Scope:
    """What a range of commits says about each issue, kept apart by strength."""

    closes: dict[int, list[str]] = field(default_factory=dict)
    refs: dict[int, list[str]] = field(default_factory=dict)

    def __contains__(self, number: int) -> bool:
        return number in self.closes or number in self.refs

    def count(self, number: int) -> int:
        return len(self.closes.get(number, [])) + len(self.refs.get(number, []))


@dataclass
class Commits:
    """Which commits name which issue, how strongly, and where they sit."""

    off_main: Scope = field(default_factory=Scope)
    unreleased: Scope = field(default_factory=Scope)
    released: Scope = field(default_factory=Scope)
    unreleased_total: int = 0
    last_tag: str | None = None

    def shipped_milestones(self) -> frozenset[str]:
        """Milestones a `prod-*` tag exists for, so they are demonstrably out.

        docs/3.3: *"`Closes #N` fires when the commit reaches the default
        branch — written, not shipped. So commits say `Refs #N`, and the
        milestone means 'in production' — the deploy is what closes them."*
        That makes the milestone, not the commit, the delivery evidence for
        anything taking the release route.
        """
        tags = {t.removeprefix("prod-") for t in
                _git("tag", "--list", "prod-*").split() if t}
        return frozenset(tags)

    def state_of(self, number: int, live_at_merge: bool,
                 milestone: str | None = None,
                 shipped: frozenset[str] = frozenset()) -> str:
        """Where this change is. One rule, used by every block of R3.

        Two things decide it, and neither is a field anybody maintains.

        **How strongly a commit names the issue.** `Closes` completes it;
        `Refs` only says work touched it. An open issue whose only evidence is
        a `Refs` has not been delivered by that commit and must not read as
        though it had.

        **`live_at_merge`, from the Route and not the type.** A Repository
        Change reaches its users the moment it merges, so *awaiting release*
        is wrong for it. Reading this off the type made nine closed changes
        pile up under "done, not yet released" when all of them were out.

        Order is newest-work-first: asking "is it released" before "is work
        happening" made an issue with old commits and a live branch read as
        released, the one state that stops anybody looking at it again.
        """
        if number in self.off_main:
            return "in progress"
        if number in self.unreleased.closes:
            return "closed by a commit on main"
        if number in self.unreleased.refs:
            return "merged" if live_at_merge else "merged, awaiting release"
        if number in self.released.closes:
            return "released"
        # **The milestone is the delivery evidence, with or without commits.**
        # docs/3.3: the deploy is what closes an issue, and the milestone means
        # "in production". A package split out of its parent after the work
        # landed has no commits of its own and is still shipped -- #362 read as
        # `not started` at Post-deployment on milestone 0.8.0, which R7 caught
        # by disagreeing with `status.sh`.
        if milestone and milestone in shipped:
            return f"released in {milestone}"
        if number in self.released.refs:
            # Named by a commit already in production. On its own that is not
            # delivery: `Refs` permits a passing mention.
            return f"mentioned before {self.last_tag or 'the last release'}"
        return "not started"


def last_release_at() -> float | None:
    """When the most recent `prod-*` tag was created, as a unix time.

    The clock a shipped-but-still-open project is measured against: a project
    that shipped and was still open when the *next* release went out has been
    overtaken, whatever its phase says.
    """
    out = _git("for-each-ref", "--sort=-creatordate",
               "--format=%(creatordate:unix)", "refs/tags/prod-*")
    first = out.split("\n")[0].strip() if out else ""
    try:
        return float(first)
    except ValueError:
        return None


def commits(main: str = "origin/main") -> Commits:
    got = Commits()

    def collect(rev: list[str]) -> Scope:
        scope = Scope()
        text = _git("log", "--no-merges", "--format=%H%x1f%B%x1e", *rev)
        for entry in text.split("\x1e"):
            if "\x1f" not in entry:
                continue
            sha, body = entry.split("\x1f", 1)
            closing = {int(n) for n in CLOSES.findall(body)}
            for number in closing:
                scope.closes.setdefault(number, []).append(sha.strip())
            # A commit that closes an issue is not also merely referencing it.
            for number in {int(n) for n in MENTIONS.findall(body)} - closing:
                scope.refs.setdefault(number, []).append(sha.strip())
        return scope

    tags = [t for t in _git("tag", "--list", "prod-*", "--sort=-creatordate").split() if t]
    got.last_tag = tags[0] if tags else None

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
        got.unreleased = collect([main])
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


def ci_red_on_main() -> str | None:
    """The `push:main` run's conclusion, if it concluded and failed.

    Delegates to `ci-status.sh` rather than asking GitHub again: that script
    is already the release gate `deploy.sh` trusts, and a second opinion about
    whether CI passed is exactly the duplication this model exists to remove.

    A run still in progress, or none at all, is **not** a failure -- "concluded"
    has to appear before this says anything, because an absent answer must not
    read as a red one any more than as a green one.
    """
    script = Path(__file__).resolve().parent.parent / "ci-status.sh"
    if not script.exists():
        return None
    try:
        out = subprocess.run([str(script), "--run", "push:main"],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode == 0:
        return None
    text = (out.stdout or "") + (out.stderr or "")
    if "concluded" not in text:
        return None
    for line in text.splitlines():
        if "concluded" in line:
            return line.strip()
    return None


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
