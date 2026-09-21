"""The only place that talks to GitHub.

Option ids and GraphQL live here and nowhere else. Everything above this layer
works in field *names*, because an option id is a fact about the GitHub
instance and not about the process.

Measured 2026-09-18: the whole open board with bodies is one query at 4.6s;
without bodies, 1.9s. Per-issue fetching, which the bash scripts do, is 0.6s
each — `status.sh` spends 46s building a picture this builds in under five.
"""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Sequence

from .model import RawIssue, RawSubIssue

OWNER = "delphside"
REPO = "tile-lite-elite"

_QUERY = """
query($owner:String!, $repo:String!, $cursor:String, $states:[IssueState!]) {
  repository(owner:$owner, name:$repo) {
    issues(first:100, after:$cursor, states:$states,
           orderBy:{field:CREATED_AT, direction:DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title state createdAt updatedAt closedAt %(body)s
        issueType { name }
        milestone { title }
        parent { number }
        labels(first:20) { nodes { name } }
        subIssues(first:50) { nodes { number issueType { name } } }
        blockedBy(first:20) { nodes { number } }
        blocking(first:20) { nodes { number } }
        issueFieldValues(first:20) {
          nodes { ... on IssueFieldSingleSelectValue {
                    value field { ... on IssueFieldCommon { name } } } }
        }
      }
    }
  }
}
"""


_PR_QUERY = """
query($owner:String!, $repo:String!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequests(first:50, after:$cursor, states:%(pr_states)s,
                 orderBy:{field:CREATED_AT, direction:DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title state body createdAt updatedAt
        isDraft reviewDecision
        reviewRequests(first:1) { totalCount }
        milestone { title }
        labels(first:20) { nodes { name } }
      }
    }
  }
}
"""


def pr_state(draft: bool, review: str | None, reviewers: int,
             state: str | None = None) -> str:
    """GitHub's own state, read as the board's `PR State`.

    The same ladder, in the same order, as `scripts/sync-pr-state.sh`, which is
    what writes the field. Two answers to one question is the disagreement this
    model exists to remove, so this reproduces that script rather than deciding
    for itself.

    **It reproduced only part of it until 2026-09-21.** The script tests MERGED
    and CLOSED before anything else; this began at `draft`, so a closed pull
    request read as `Drafting` -- #393 did, in R2's first run, hours after the
    board itself had been corrected to `Closed`. The comment claimed the
    parallel run would catch a divergence, and nothing was comparing them.
    """
    if state == "MERGED":
        return "Merged"
    if state == "CLOSED":
        return "Closed"
    if draft:
        return "Drafting"
    if review == "APPROVED":
        return "Approved"
    if review == "CHANGES_REQUESTED":
        return "Changes requested"
    if reviewers:
        return "Awaiting review"
    return "Drafting"


class Unavailable(Exception):
    """A source did not answer. Never returns a default — a gate that cannot
    see the data must refuse, not report that it found no problem."""


@dataclass(frozen=True)
class Snapshot:
    """One fetch. Every fact a consumer uses comes from one of these.

    `pages` matters: a single page is an instant, several are a window during
    which the board can move. 45 open issues fit one page today, which is a
    fact about the current size and not a property of the design.
    """

    issues: tuple[RawIssue, ...]
    started_at: float
    finished_at: float
    pages: int
    with_bodies: bool

    @property
    def age(self) -> float:
        return time.time() - self.finished_at

    @property
    def window(self) -> float:
        return self.finished_at - self.started_at


def _gh_graphql(query: str, partial: bool = False, **variables) -> dict:
    """Run a GraphQL query through `gh`.

    `partial` allows a query whose *fields* can fail while the response still
    carries data -- an aliased lookup of several issues where one number does
    not exist returns every other one beside the error, and `gh` still exits
    non-zero. Without it the whole answer is thrown away because one field was
    absent, which for R9 is the very case being asked about.

    It is off by default: everywhere else, a refusal is a refusal.
    """
    args = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        args += ["-F" if isinstance(value, (int, bool)) else "-f", f"{key}={value}"]
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Unavailable(f"GitHub did not answer: {exc}") from exc
    if out.returncode != 0:
        if partial and out.stdout.strip():
            try:
                payload = json.loads(out.stdout)
            except json.JSONDecodeError:
                raise Unavailable(f"GitHub refused: {out.stderr.strip()[:300]}") from None
            if payload.get("data"):
                return payload
        raise Unavailable(f"GitHub refused: {out.stderr.strip()[:300]}")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        raise Unavailable(f"GitHub returned no JSON: {exc}") from exc


def _to_raw(node: dict) -> RawIssue:
    fields = {
        n["field"]["name"]: n["value"]
        for n in node.get("issueFieldValues", {}).get("nodes", [])
        if n and n.get("field", {}).get("name")
    }
    subs = tuple(
        RawSubIssue(s["number"], (s.get("issueType") or {}).get("name"))
        for s in node.get("subIssues", {}).get("nodes", [])
        if s
    )
    return RawIssue(
        number=node["number"],
        title=node.get("title") or "",
        state=node.get("state") or "",
        body=node.get("body") or "",
        issue_type=(node.get("issueType") or {}).get("name"),
        fields=fields,
        sub_issues=subs,
        parent=(node.get("parent") or {}).get("number"),
        milestone=(node.get("milestone") or {}).get("title"),
        labels=frozenset(
            n["name"] for n in node.get("labels", {}).get("nodes", []) if n
        ),
        # `blockedBy` is {nodes: [...]}, not a list. The shape crashed
        # roadmap-diagram.py the first time it ran, so it is named here once
        # and never guessed at again.
        blocked_by=frozenset(
            n["number"] for n in (node.get("blockedBy") or {}).get("nodes", []) if n
        ),
        blocks=frozenset(
            n["number"] for n in (node.get("blocking") or {}).get("nodes", []) if n
        ),
        created_at=node.get("createdAt"),
        updated_at=node.get("updatedAt"),
        closed_at=node.get("closedAt"),
    )


def _pr_to_raw(node: dict) -> RawIssue:
    state = pr_state(bool(node.get("isDraft")),
                     node.get("reviewDecision") or None,
                     (node.get("reviewRequests") or {}).get("totalCount", 0),
                     node.get("state"))
    return RawIssue(
        number=node["number"],
        title=node.get("title") or "",
        state=node.get("state") or "",
        body=node.get("body") or "",
        # A pull request carries no issue type -- GitHub does not offer one --
        # so the model supplies it. Without this the fourth type is a class
        # nothing ever instantiates.
        issue_type="PullRequest",
        fields={"PR State": state},
        sub_issues=(),
        parent=None,
        milestone=(node.get("milestone") or {}).get("title"),
        labels=frozenset(
            n["name"] for n in node.get("labels", {}).get("nodes", []) if n
        ),
        created_at=node.get("createdAt"),
        updated_at=node.get("updatedAt"),
        closed_at=node.get("closedAt"),
    )


def step_ages(wanted: Sequence[tuple[int, str, str]]) -> dict[int, float]:
    """Days since each issue's field last became the value the caller asks for.

    **The value is a parameter, not the current one.** R1 passes the step an
    issue holds now, which is what this was written for; `overtaken.py` passes
    `Post-deployment` for projects that have since moved to `Project Closedown`,
    and gets the date it shipped rather than the date it stopped. The docstring
    said "the value it holds now" until 2026-09-21 and the second caller had to
    read the loop to be sure.

    **The clock is GitHub's, not ours.** A field *value* carries no timestamp,
    but the issue records every change: `IssueFieldChangedEvent` and
    `IssueFieldAddedEvent` are timeline items with `createdAt`. So nothing has
    to be stored, and a field moved by hand is dated exactly like one moved by
    `deploy.sh`.

    **Matched on the value moved *to*, as it was named at the time.** The
    events keep the old option name and renaming does not rewrite them -- the
    `Scope and design` option became `Scope` on 2026-08-31, so anything
    matching against the current option list would silently miss every event
    before that date.

    Asked only for the issues a caller actually needs, which is a handful:
    widening the whole-board query with timelines would cost far more than it
    returns. Taken from `actions.py`, which had the only correct answer to
    "how long has it been that way" in the repository.
    """
    ages: dict[int, float] = {}
    wanted = [w for w in wanted if w[1] and w[2]]
    for start in range(0, len(wanted), 25):
        chunk = wanted[start:start + 25]
        parts = " ".join(
            f'i{n}: issue(number:{n}) {{ number timelineItems(last:40, '
            "itemTypes:[ISSUE_FIELD_CHANGED_EVENT, ISSUE_FIELD_ADDED_EVENT]) { nodes { "
            "... on IssueFieldChangedEvent { createdAt newValue "
            "issueField { ... on IssueFieldSingleSelect { name } } } "
            "... on IssueFieldAddedEvent { createdAt value "
            "issueField { ... on IssueFieldSingleSelect { name } } } } } }"
            for n, _, _ in chunk)
        query = f'{{ repository(owner:"{OWNER}", name:"{REPO}") {{ {parts} }} }}'
        try:
            payload = _gh_graphql(query)
        except Unavailable:
            # A clock we cannot read is not an age we should invent.
            return ages
        # **Partial data is still data.** One bad alias -- a pull request
        # number handed to `issue(number:)`, which is the shape that broke
        # this -- makes GitHub answer with `errors` and null that entry while
        # every other one comes back fine. Returning early on `errors` threw
        # away the ages it did fetch, so R1 said "today" about something that
        # had waited twelve days.
        block = ((payload.get("data") or {}).get("repository") or {})
        by_number = {n: (field, value) for n, field, value in chunk}
        for node in block.values():
            if not isinstance(node, dict) or "number" not in node:
                continue
            field, value = by_number.get(node["number"], (None, None))
            when = None
            for event in node.get("timelineItems", {}).get("nodes", []):
                if not event or (event.get("issueField") or {}).get("name") != field:
                    continue
                if (event.get("newValue") or event.get("value")) == value:
                    when = event.get("createdAt")
            if when:
                moved = datetime.fromisoformat(when.replace("Z", "+00:00"))
                ages[node["number"]] = (
                    datetime.now(timezone.utc) - moved).total_seconds() / 86400
    return ages


@dataclass(frozen=True)
class Remark:
    """One thing somebody said, on an issue or on a diff."""

    number: int
    when: str
    who: str          # "owner" | "claude" | "deploy"
    text: str
    on_diff: bool


def comments_since(since_iso: str) -> tuple[Remark, ...]:
    """Every comment on an issue or a pull request updated since `since_iso`.

    **Two endpoints, because a review on a diff is not an issue comment.**
    Inline code comments live on `pulls/comments` and would otherwise be
    invisible -- which is the half `inbox.sh` had to learn twice.

    **`since` is on *updated*, so an edited older comment surfaces**, and that
    is right: an edit is a change you have not seen.

    **Who typed it is the account, and only the account.** Claude posts through
    `gh`, which authenticates as `SteveStyle-typed-by-Claude`; the owner types in
    a browser as himself. Owner, 2026-09-21: *"We no longer use the footer in
    comments, we rely on the different GitHub accounts."*

    **This was settled on 2026-09-03 and re-learned here.** `.claude/turn-check.sh`
    had already dropped the `Typed by Claude` test, having checked the thirty
    most recent comments and found the marker on **none** of them -- every
    comment Claude had written qualified as the owner's. Written footer-first
    here anyway, it mislabelled 46 of Claude's comments, and the whole value of
    this report is that `>` marks what the owner typed.
    **`deploy.sh` is tested first, and that is a fix.** It announces its own
    releases through the same account, so an account-first test labelled them
    Claude's and `inbox.sh`'s dimmed `[deploy.sh]` branch could never fire --
    dead since it was written.

    Raises `Unavailable` rather than returning nothing: a window that reports no
    comments because the call failed reads exactly like a quiet week, which
    `inbox.sh` did on a day four issues opened and four closed.
    """
    out: list[Remark] = []
    for endpoint, url_key, on_diff in (
        ("issues/comments", "issue_url", False),
        ("pulls/comments", "pull_request_url", True),
    ):
        jq = (f'.[] | [(.{url_key} | split("/") | last), .updated_at[0:16], '
              '(if (.body | test("^Released in prod-")) then "deploy" '
              'elif (.user.login == "SteveStyle-typed-by-Claude") then "claude" '
              'else "owner" end), (.body | gsub("[\n\r]"; " ") | .[0:150])] | @tsv')
        try:
            run = subprocess.run(
                ["gh", "api",
                 f"repos/{OWNER}/{REPO}/{endpoint}"
                 f"?since={since_iso}&sort=updated&direction=asc&per_page=100",
                 "--paginate", "--jq", jq],
                capture_output=True, text=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Unavailable(f"could not read {endpoint}: {exc}") from exc
        if run.returncode != 0:
            raise Unavailable(f"could not read {endpoint}: {run.stderr.strip()[:200]}")
        for line in run.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                continue
            number, when, who, text = parts
            try:
                out.append(Remark(int(number), when, who, text, on_diff))
            except ValueError:
                continue
    return tuple(sorted(out, key=lambda r: (r.number, r.when)))


def issues_by_number(numbers: Sequence[int]) -> dict[int, RawIssue]:
    """Just these issues, whatever state they are in.

    **For R9, which needs one or two and not the closed board.** Fetching every
    closed issue to resolve a handful of branch names took `board-check.py` from
    3.4s to 15s -- and this module's own note says a check nobody waits for is a
    check nobody runs. One aliased query, one round trip.

    A number that resolves to nothing is simply absent from the result, which is
    the case R9 reports as *names #N, which does not exist*.
    """
    if not numbers:
        return {}
    parts = " ".join(f'i{n}: issue(number:{n}) {{ number title state '
                     f'issueType {{ name }} }}' for n in sorted(set(numbers)))
    query = f'{{ repository(owner:"{OWNER}", name:"{REPO}") {{ {parts} }} }}'
    payload = _gh_graphql(query, partial=True)
    # Errors here are per-field -- a missing issue is an error beside the data,
    # not instead of it -- so the data is read even when `errors` is present.
    repo = (payload.get("data") or {}).get("repository") or {}
    out: dict[int, RawIssue] = {}
    for node in repo.values():
        if not node:
            continue
        out[node["number"]] = RawIssue(
            number=node["number"], title=node.get("title") or "",
            state=node.get("state") or "", body="",
            issue_type=(node.get("issueType") or {}).get("name"),
            fields={}, sub_issues=(), parent=None, milestone=None,
            labels=frozenset())
    return out


def remote_branches(remote: str = "origin") -> tuple[str, ...]:
    """Branch names on the remote.

    **The remote, not the local checkout.** A local branch is one person's
    working state; a branch on the remote is the shared record, and R9 is about
    the relationship between that record and the board. `verify.sh` already
    reports merged locals left behind, which is a different question.

    Raises `Unavailable` rather than returning nothing, for the reason the whole
    module does: no branches and could-not-ask must not read alike.
    """
    try:
        run = subprocess.run(["git", "ls-remote", "--heads", remote],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Unavailable(f"could not list branches on {remote}: {exc}") from exc
    if run.returncode != 0:
        raise Unavailable(f"could not list branches on {remote}: "
                          f"{run.stderr.strip()[:200]}")
    names = []
    for line in run.stdout.splitlines():
        _, _, ref = line.partition("\t")
        if ref.startswith("refs/heads/"):
            names.append(ref[len("refs/heads/"):])
    return tuple(sorted(names))


def token_days_left() -> int | None:
    """Days until the token `gh` runs on expires; None if it does not or the
    header is missing.

    A countdown rather than a warning under a threshold -- owner, 2026-09-04:
    there is no right number of days to start caring, and a figure that is
    always there needs no decision about when to appear.

    #309: the fine-grained token expires 2026-11-24 and nothing warns. GitHub
    emails 45 days ahead about 2FA and says nothing at all about this, so the
    first symptom would be a command failing in the middle of something else.

    UTC on both sides. The header is UTC and a local `today()` is not, so
    between midnight BST and midnight UTC they are different days and the
    countdown is out by one -- which is exactly when the test caught it.
    """
    try:
        out = subprocess.run(["gh", "api", "-i", "user", "--silent"],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in (out.stdout + out.stderr).splitlines():
        if line.lower().startswith("github-authentication-token-expiration:"):
            when = line.split(":", 1)[1].strip()
            for fmt in ("%Y-%m-%d %H:%M:%S %Z", "%Y-%m-%d %H:%M:%S UTC"):
                try:
                    expiry = datetime.strptime(when, fmt)
                except ValueError:
                    continue
                return (expiry.date() - datetime.now(timezone.utc).date()).days
    return None


def fetch(states: str = "OPEN", with_bodies: bool = True,
          with_pull_requests: bool = True,
          pr_states: str = "OPEN") -> Snapshot:
    """One snapshot of the board.

    Bodies are 2.7s of the 4.6s and 92% of the payload, so a consumer that
    reads no body headings should ask for none.
    """
    # **Pull requests are not issues.** GraphQL's `issues` connection excludes
    # them, so a snapshot built from it alone contains no `PullRequest` at all
    # -- `classify` never reaches that branch, both PR obligations apply to
    # nothing, and R1 cannot see a review waiting on the owner. Every one of
    # those reads as "nothing to report", which is the defect family this model
    # exists to remove: a consumer asking a source for something it never
    # carried, and taking the silence for good news.
    query = _QUERY % {"body": "body" if with_bodies else ""}
    started = time.time()
    issues: list[RawIssue] = []
    cursor = None
    pages = 0
    while True:
        payload = _gh_graphql(
            query, owner=OWNER, repo=REPO, cursor=cursor, states=states
        )
        if "errors" in payload:
            raise Unavailable(str(payload["errors"])[:300])
        block = payload["data"]["repository"]["issues"]
        issues += [_to_raw(n) for n in block["nodes"] if n]
        pages += 1
        if not block["pageInfo"]["hasNextPage"]:
            break
        cursor = block["pageInfo"]["endCursor"]

    if with_pull_requests and states == "OPEN":
        cursor = None
        while True:
            payload = _gh_graphql(_PR_QUERY % {"pr_states": pr_states},
                                  owner=OWNER, repo=REPO, cursor=cursor)
            if "errors" in payload:
                raise Unavailable(str(payload["errors"])[:300])
            block = payload["data"]["repository"]["pullRequests"]
            issues += [_pr_to_raw(n) for n in block["nodes"] if n]
            pages += 1
            if not block["pageInfo"]["hasNextPage"]:
                break
            cursor = block["pageInfo"]["endCursor"]

    return Snapshot(
        issues=tuple(issues),
        started_at=started,
        finished_at=time.time(),
        pages=pages,
        with_bodies=with_bodies,
    )
