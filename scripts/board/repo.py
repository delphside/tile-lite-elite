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
#
# **Case-sensitive, like `issue-mentions.sh`.** All 890 trailers in the history
# are capitalised, so matching case-insensitively does not tolerate drift, it
# admits prose -- which is #320 again, in the one place that had been fixed
# everywhere else. Measured 2026-09-21, exactly two commits were matched on
# their prose and both said something the trailer would not have:
#
#     76d9ad1  "#391 no `Refs #N` - fixed, it now refs #301"
#     7d43285  "That closes #311 Q1."
#
# The first credited #301, the parent whose delivery-2 package is the very
# case #375 exists for. The second is worse: a prose `closes` read as a
# *closing* trailer, the strongest evidence `state_of` has, so a sentence
# about a question in #311 was the reason #311 read as closed by a commit.
CLOSES = re.compile(r"\b(?:Closes|Fixes|Resolves)\s+#(\d+)")
MENTIONS = re.compile(r"\bRefs\s+#(\d+)")


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


# **A change document is not a delivery.** `docs/changes/` holds a project's
# own design, impact and test notes -- docs/3.6: *"a workstream's note lives on
# `main` for the life of the workstream"*, which is why writing one lands on
# `main` while the project is still in design. A commit touching nothing else
# has therefore delivered nothing to anybody, and counting it as delivery
# evidence reported #291 as *merged, awaiting release* on the day its design
# note was written, and then reported the contradiction against the board.
# 131 of the history's 1191 commits touch only this path.
NOTES = "docs/changes/"


def _delivers(paths: list[str]) -> bool:
    """Did this commit change a programme asset, or only a project's notes?

    An empty list is *unknown*, not *nothing*: `--name-only` prints no paths
    for a merge commit, and the milestone check counts merges on purpose.
    """
    return not paths or any(not p.startswith(NOTES) for p in paths)


def _scope(rev: list[str], no_merges: bool = True,
           notes_count: bool = True) -> Scope:
    """What the commits in `rev` say about each issue.

    `no_merges` is a caller's decision rather than this function's, because the
    two callers want opposite answers and both are right. `commits()` counts
    work, and a merge commit is not work -- counting it would report the
    branch's commits twice. The milestone check asks *does anything on main
    claim this issue*, and a merge is a trailer somebody wrote: #362's only
    `Refs` in the whole history is on `1cac857`, a merge into a release branch,
    and dropping it would call a shipped package unbuilt.

    `notes_count` is the same shape of decision. *Where has this change got to*
    must not count a change document; *does anything on main claim this issue*
    must, because that is the question `issue-mentions.sh` answers for
    `deploy.sh`'s gate and the two disagreeing is worse than either being
    wrong.
    """
    scope = Scope()
    args = ["log", "--format=%x1e%H%x1f%B%x1f", "--name-only"]
    if no_merges:
        args.insert(1, "--no-merges")
    text = _git(*args, *rev)
    for entry in text.split("\x1e"):
        if entry.count("\x1f") < 2:
            continue
        sha, body, names = entry.split("\x1f", 2)
        if not notes_count:
            paths = [line for line in names.splitlines() if line.strip()]
            if not _delivers(paths):
                continue
        closing = {int(n) for n in CLOSES.findall(body)}
        for number in closing:
            scope.closes.setdefault(number, []).append(sha.strip())
        # A commit that closes an issue is not also merely referencing it.
        for number in {int(n) for n in MENTIONS.findall(body)} - closing:
            scope.refs.setdefault(number, []).append(sha.strip())
    return scope


def mentions_on(ref: str = "origin/main") -> Scope:
    """Every trailer reachable from `ref`, merges included.

    The milestone check's question, and deliberately the same one
    `issue-mentions.sh` answers for `deploy.sh`'s gate: same trailers, same
    case-sensitivity, merges counted. The pre-flight and the gate disagreeing
    is worse than either being wrong on its own -- the pre-flight would pass
    and the deploy would then refuse, with nothing saying why.

    **`origin/main`, where `verify.sh` asked `HEAD`.** Built means built on
    main; a commit sitting on a branch is `in progress`, which is a different
    row of the same report. `verify.sh` asserts the two are equal anyway, one
    check earlier.
    """
    return _scope([ref], no_merges=False)


def commits(main: str = "origin/main") -> Commits:
    got = Commits()

    tags = [t for t in _git("tag", "--list", "prod-*", "--sort=-creatordate").split() if t]
    got.last_tag = tags[0] if tags else None

    got.off_main = _scope(["--all", f"^{main}"], notes_count=False)
    # Anything already in the last production tag is out, whatever the board
    # says. The board is a plan; the tag is what happened. What sits between
    # the tag and `main` is the other half, and the two must be asked
    # separately -- `released` walks all history reachable from the tag, so on
    # its own it cannot tell shipped-long-ago from shipped-and-since-changed.
    if got.last_tag:
        got.released = _scope([got.last_tag], notes_count=False)
        got.unreleased = _scope([f"{got.last_tag}..{main}"],
                                notes_count=False)
    else:
        got.unreleased = _scope([main], notes_count=False)
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


@dataclass(frozen=True)
class RunningOn:
    """Where an environment's commit sits, for a reader asking what it runs.

    **"Up to date with main" was true and misleading.** Preview ran a project
    branch's tip, which had everything on `main` and more, so it counted
    nothing behind and said "up to date with main" -- while running a pull
    request that was not on `main` at all (#420, 2026-09-26). A commit that is
    not on `main` is described by the branch it is on.
    """

    on_main: bool
    branch: str | None = None      # a remote branch holding the commit
    at_tip: bool = False           # that branch's newest commit is this one


def running_on(version: str | None, main: str = "origin/main") -> RunningOn | None:
    """None when the version carries no commit or the commit is not here."""
    if not version or "+" not in version:
        return None
    sha = version.split("+", 1)[1]
    full = _git("rev-parse", "-q", "--verify", f"{sha}^{{commit}}").strip()
    if not full:
        return None
    if subprocess.run(["git", "merge-base", "--is-ancestor", full, main],
                      capture_output=True).returncode == 0:
        return RunningOn(on_main=True)
    main_name = main.removeprefix("origin/")
    at_tip = [line.strip().removeprefix("origin/") for line in
              _git("for-each-ref", "--points-at", full, "--format=%(refname:short)",
                   "refs/remotes/origin").splitlines()]
    at_tip = [b for b in at_tip if b and b not in (main_name, "HEAD", "origin")]
    if at_tip:
        return RunningOn(on_main=False, branch=sorted(at_tip)[0], at_tip=True)
    holding = [line.strip().removeprefix("origin/") for line in
               _git("branch", "-r", "--contains", full,
                    "--format=%(refname:short)").splitlines()]
    holding = [b for b in holding if b and b not in (main_name, "HEAD", "origin")]
    return RunningOn(on_main=False, branch=sorted(holding)[0] if holding else None)


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
