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
        number title state %(body)s
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


def _gh_graphql(query: str, **variables) -> dict:
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
    )


def fetch(states: str = "OPEN", with_bodies: bool = True) -> Snapshot:
    """One snapshot of the board.

    Bodies are 2.7s of the 4.6s and 92% of the payload, so a consumer that
    reads no body headings should ask for none.
    """
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
    return Snapshot(
        issues=tuple(issues),
        started_at=started,
        finished_at=time.time(),
        pages=pages,
        with_bodies=with_bodies,
    )
