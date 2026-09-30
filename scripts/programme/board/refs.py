"""Which issue a commit, a pull request or a branch names — decided once.

Everything that asks "does this belong to issue N" asks here: the model's
reports, `deploy.sh`'s gate through `issue-mentions.sh`, and the commit-msg
hook through `scripts/programme/board/board-refs.py`. Until 2026-09-26 there were six copies,
and they disagreed (#421).

**The trailer is `Refs #N` or `Closes #N`, capitalised, one space.** Not
GitHub's closing keywords, which close an issue in any case: this answers a
different question, and the case-sensitive form is what keeps prose out.
`issue-mentions.sh` measured it at `9293893` — it drops exactly the prose
mentions and keeps every real trailer — and it was measured again on
2026-09-26: `Refs` 1050, `Closes` 31, nothing else. The design note is in
`docs/changes/workstreams/delivery-tooling/383-one-board-model/model.md`.

Pure: text in, numbers out. Reading git is `repo.py`'s.
"""

from __future__ import annotations

import re

_TRAILER = re.compile(r"\b(Refs|Closes) #(\d+)\b")
_TITLE_LEAD = re.compile(r"^#(\d+)\b")
_BRANCH = re.compile(r"^(?:issue-)?(\d+)-")


def closes(text: str) -> set[int]:
    """Issues a message closes: its `Closes #N` trailers."""
    return {int(n) for kind, n in _TRAILER.findall(text) if kind == "Closes"}


def named(text: str) -> set[int]:
    """Issues a message names at all: `Refs #N` or `Closes #N`."""
    return {int(n) for _, n in _TRAILER.findall(text)}


def pull_request_names(title: str, body: str) -> set[int]:
    """Issues a pull request is for: its title's leading `#N`, and its body's
    trailers. The title carries the work package (`#414 Scheduler core`); the
    body can name it too, and names the parent when a branch predates a split.
    """
    found = named(body)
    m = _TITLE_LEAD.match(title)
    if m:
        found.add(int(m.group(1)))
    return found


def branch_issue(branch: str) -> int | None:
    """The issue a branch is for, from its name: `N-…`, or the older `issue-N-…`.

    A remote-tracking name is accepted as its branch (`origin/415-x`).
    """
    m = _BRANCH.match(branch.removeprefix("origin/"))
    return int(m.group(1)) if m else None
