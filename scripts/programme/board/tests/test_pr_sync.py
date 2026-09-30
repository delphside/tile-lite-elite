"""The board's `PR State`, written from GitHub's own state: which pull requests
need adding or correcting, and what a run counts. On canned records, with no
network. The rules are `scripts/programme/board/board-pr-state.py`'s help and
`scripts/programme/board/pr_sync.py`'s header:

  the ladder   merged and closed before anything else; then draft; approved;
               changes requested; a review requested; otherwise drafting
  missing      a pull request not on the board is added, then set
  failed add   reported, not counted as added, and nothing set on it
  --check      reports the same drift and changes nothing
  nobody       an open, ready pull request requesting nobody is reported
"""

import os
import tempfile
from pathlib import Path

from board.model import RawBoardItem, RawPullRequest
from board.pr_sync import apply, check, plan, want
from board.sources import Unavailable

from .cases import Cases
from .cli import run


def pr(number=1, state="OPEN", draft=False, review=None, reviewers=1, reviews=0):
    return RawPullRequest(number, f"PR_{number}", state, draft, review, reviewers, reviews)


def on_board(number=1, value=None):
    return RawBoardItem(number, f"PVTI_{number}", value)


class Board:
    """A fake GitHub: records every add and set, refuses what it is told to."""

    def __init__(self, refuse_add=(), refuse_set=()):
        self.added, self.set = [], []
        self.refuse_add, self.refuse_set = refuse_add, refuse_set

    def add(self, node_id):
        if node_id in self.refuse_add:
            raise Unavailable("refused")
        self.added.append(node_id)
        return "PVTI_new_" + node_id

    def set_value(self, item, value):
        if item in self.refuse_set:
            raise Unavailable("refused")
        self.set.append((item, value))


def run_plain(prs, board_items, fake=None):
    fake = fake or Board()
    return fake, apply(plan(prs, board_items), fake.add, fake.set_value, "SteveStyle")


class TheLadder(Cases):
    def test_merged_and_closed_come_before_anything_else(self):
        self.expect("merged, even as an approved draft", "Merged",
                    want(pr(state="MERGED", draft=True, review="APPROVED")))
        self.expect("closed, even with changes requested", "Closed",
                    want(pr(state="CLOSED", review="CHANGES_REQUESTED")))

    def test_then_draft_approved_changes_requested_requested_else_drafting(self):
        self.expect("a draft is drafting, approval included", "Drafting",
                    want(pr(draft=True, review="APPROVED")))
        self.expect("approved", "Approved", want(pr(review="APPROVED", reviewers=0)))
        self.expect("changes requested", "Changes requested",
                    want(pr(review="CHANGES_REQUESTED")))
        self.expect("a review requested and no decision", "Awaiting review",
                    want(pr(reviewers=1)))
        self.expect("nothing requested and no decision", "Drafting",
                    want(pr(reviewers=0)))


class WhatARunDoes(Cases):
    def test_a_board_that_agrees_needs_nothing(self):
        self.expect("no drift", [], plan([pr(reviewers=1)], [on_board(1, "Awaiting review")]))
        fake, tally = run_plain([pr(reviewers=1)], [on_board(1, "Awaiting review")])
        self.expect("nothing written", ([], []), (fake.added, fake.set))

    def test_a_wrong_value_is_corrected_to_githubs(self):
        fake, tally = run_plain([pr(state="MERGED")], [on_board(1, "Approved")])
        self.expect("set to what GitHub says", [("PVTI_1", "Merged")], fake.set)
        self.expect("counted", 1, tally.corrected)
        self.expect("said", True, any("#1 Approved -> Merged" in t for _, t in tally.lines))

    def test_an_unset_value_is_corrected(self):
        fake, tally = run_plain([pr(state="CLOSED")], [on_board(1, None)])
        self.expect("set", [("PVTI_1", "Closed")], fake.set)

    def test_a_pull_request_not_on_the_board_is_added_then_set(self):
        fake, tally = run_plain([pr(7, review="APPROVED")], [on_board(1, "Merged")])
        self.expect("added", ["PR_7"], fake.added)
        self.expect("counted as added", 1, tally.added)
        self.expect("and its state set on the new item",
                    [("PVTI_new_PR_7", "Approved")], fake.set)

    def test_a_failed_add_is_reported_and_not_counted(self):
        fake, tally = run_plain([pr(7)], [], Board(refuse_add={"PR_7"}))
        self.expect("not counted as added", 0, tally.added)
        self.expect("reported, on stderr", True,
                    (True, "  #7 could not be added") in tally.lines)
        self.expect("nothing set on an item that does not exist", [], fake.set)

    def test_a_failed_set_is_not_counted_as_corrected(self):
        fake, tally = run_plain([pr(state="MERGED")], [on_board(1, "Approved")],
                                Board(refuse_set={"PVTI_1"}))
        self.expect("not counted", 0, tally.corrected)
        self.expect("reported", True, any("could not be set" in t for _, t in tally.lines))

    def test_check_reports_the_same_drift_and_changes_nothing(self):
        drifts = plan([pr(1, state="MERGED"), pr(2, reviewers=1), pr(3)],
                      [on_board(1, "Approved"), on_board(3, "Awaiting review")])
        tally = check(drifts, "SteveStyle")
        self.expect("each drifted pull request counted once", 2, tally.drifted)
        self.expect("the wrong value named", True,
                    ("  #1 says 'Approved', GitHub says 'Merged'") in [t for _, t in tally.lines])
        self.expect("the missing one named with what it should be", True,
                    ("  #2 is not on the board — should be 'Awaiting review'")
                    in [t for _, t in tally.lines])
        self.expect("nothing added or corrected", (0, 0), (tally.added, tally.corrected))


class WaitingOnNobody(Cases):
    def test_an_open_ready_pull_request_requesting_nobody_is_reported(self):
        tally = check(plan([pr(5, reviewers=0)], [on_board(5, "Drafting")]), "SteveStyle")
        self.expect("counted", 1, tally.unrequested)
        self.expect("the request is printed for a person to run, naming the reviewer",
                    True, any("reviewers[]=SteveStyle" in t for _, t in tally.lines))

    def test_but_not_a_draft_a_reviewed_one_or_one_requesting_somebody(self):
        for name, p in (("a draft", pr(reviewers=0, draft=True)),
                        ("one with a review given", pr(reviewers=0, reviews=1)),
                        ("one with a decision", pr(reviewers=0, review="APPROVED")),
                        ("one requesting somebody", pr(reviewers=1)),
                        ("a merged one", pr(reviewers=0, state="MERGED"))):
            self.expect(name, 0, check(plan([p], [on_board(1, want(p))]), "x").unrequested)


class TheCommand(Cases):
    def test_help_lists_its_messages_and_exits_0(self):
        out = run("programme/board/board-pr-state.py", "--help")
        self.expect("exit 0", 0, out.returncode)
        for message in ("is not on the board", "GitHub says", "could not be added",
                        "no 'PR State' field on the project"):
            self.expect(message, True, message in out.stdout)


# A stub `gh`, first on PATH, answering the command's three reads from what the
# test puts in its environment: GH_FAIL names the read that refuses (field,
# prs, board), BOARD_VALUE is pull request #1's `PR State` on the board, which
# GitHub says is merged. Any write exits 9, so `--check` is seen to make none.
_STUB_GH = r'''#!/usr/bin/env python3
import json, os, sys
query = next((a[len("query="):] for a in sys.argv if a.startswith("query=")), "")
fail = os.environ.get("GH_FAIL", "")
def answer(what, data):
    if fail == what:
        print("stub: refused", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"data": data}))
    sys.exit(0)
if "mutation" in query:
    sys.exit(9)
if "ProjectV2SingleSelectField" in query:
    answer("field", {"node": {"fields": {"nodes": [{"id": "F", "name": "PR State",
        "options": [{"id": "o" + n, "name": n} for n in
                    ("Drafting", "Awaiting review", "Approved", "Merged", "Closed")]}]}}})
if "pullRequests(" in query:
    answer("prs", {"repository": {"pullRequests": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [{"id": "PR_1", "number": 1, "state": "MERGED", "isDraft": False,
                   "reviewDecision": "APPROVED", "reviewRequests": {"totalCount": 0},
                   "reviews": {"totalCount": 1}}]}}})
if "items(first:100" in query:
    answer("board", {"node": {"items": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [{"id": "PVTI_1", "content": {"number": 1}, "fieldValues": {"nodes": [
            {"name": os.environ.get("BOARD_VALUE", "Merged"), "field": {"name": "PR State"}}]}}]}}})
print("stub: unexpected query", file=sys.stderr)
sys.exit(8)
'''


class TheCommandsExitStatuses(Cases):
    """`board-pr-state.py` run as its callers run it, against a stub `gh`."""

    @classmethod
    def setUpClass(cls):
        cls._dir = tempfile.TemporaryDirectory()
        gh = Path(cls._dir.name) / "gh"
        gh.write_text(_STUB_GH)
        gh.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls._dir.cleanup()

    def check(self, **env):
        full = dict(os.environ, PATH=f"{self._dir.name}{os.pathsep}{os.environ['PATH']}",
                    **env)
        return run("programme/board/board-pr-state.py", "--check", env=full)

    def test_check_exits_1_on_drift_and_0_when_the_board_agrees(self):
        drift = self.check(BOARD_VALUE="Approved")
        self.expect("drift exits 1", 1, drift.returncode)
        self.expect("and names it", True,
                    "#1 says 'Approved', GitHub says 'Merged'" in drift.stdout)
        self.expect("the board agreeing exits 0", 0, self.check(BOARD_VALUE="Merged").returncode)

    def test_a_read_that_fails_exits_2(self):
        field = self.check(GH_FAIL="field")
        self.expect("the PR State field unreadable exits 2", 2, field.returncode)
        self.expect("and says so", True,
                    "no 'PR State' field on the project" in field.stderr)
        self.expect("the pull requests unreadable exits 2", 2,
                    self.check(GH_FAIL="prs").returncode)
        self.expect("the board unreadable exits 2", 2,
                    self.check(GH_FAIL="board").returncode)
