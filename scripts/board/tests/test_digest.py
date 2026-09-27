"""The weekly digest, the `weekly-digest` activity in docs/3.8.

From docs/3.7's brake, not from the code. The cases that matter are the ones
where a bug would flatter the report or repeat a settled question:

  the measure     non-functional issues raised per week (types `tooling` and
                  `documentation`), beside the week before, and what is
                  waiting on the owner. Owner, 2026-09-21.
  the share       an observation, not the target: no threshold verdict, no
                  date, and no request to confirm what the owner has already
                  answered. Until 2026-09-27 the digest still asked.
  the window      an issue raised and closed inside the week was still raised;
                  closed means closed in the window, not merely touched
  judgement       "anything I decided that you might have decided differently"
                  cannot be derived; an empty section must say it was not
                  written, never that there was nothing

No network and no git: canned counts and issues only."""

import collections
import unittest

from board.digest import Digest, in_window, render, MEASURED_AT
from board.model import RawIssue

from .cases import Cases


def digest(tooling=48, total=100, **kw):
    d = Digest(since="2026-09-21", until="2026-09-27", tooling=tooling, total=total, **kw)
    d.by_type = collections.Counter({"tooling": tooling, "other": total - tooling})
    return d


def issue(n, kind_of_change, created, closed=None):
    return RawIssue(n, f"issue {n}", "CLOSED" if closed else "OPEN", "", "Requirement",
                    {"Type of change": kind_of_change} if kind_of_change else {}, (), None, None,
                    frozenset(), created_at=created, closed_at=closed)


class TheBrake(Cases):
    def test_non_functional_issues_raised_are_counted_beside_the_week_before(self):
        text = render(digest(non_functional=[(401, "a tooling fix")], non_functional_before=3))
        self.expect("this week's count", True, "**1** non-functional issues raised" in text)
        self.expect("beside the week before", True, "against **3** in the seven days before" in text)
        self.expect("and each is named", True, "#401 a tooling fix" in text)

    def test_what_is_waiting_on_the_owner_is_listed_or_said_to_be_nothing(self):
        self.expect("nothing waiting says nothing", True,
                    "**Nothing** the board reports as waiting on you" in render(digest()))
        one = render(digest(waiting=[(407, "Programme BAU", "tick R3")]))
        self.expect("one thing is singular", True, "**1** thing the board reports" in one)
        self.expect("and says what is asked", True, "#407 Programme BAU: tick R3" in one)

    def test_the_share_is_an_observation_not_a_verdict(self):
        text = render(digest(48, 100))
        self.expect("it is shown", True, "**48%**" in text)
        self.expect("from where it started", True, f"{MEASURED_AT}%" in text)
        self.expect("as an observation", True, "as an observation" in text)
        self.expect("with no date for a horizon", False, "2026-10-17" in text)
        # The owner answered on 2026-09-21; asking again is the defect this replaced.
        self.expect("and no request to confirm", False, "confirm" in text)

    def test_the_share_is_arithmetic(self):
        self.expect("it rounds down, never up", 48, digest(48, 100).share)
        self.expect("no issues at all does not divide by zero", 0, digest(0, 0).share)


class TheWindow(Cases):
    START = "2026-09-21"

    def test_raised_counts_open_and_closed_alike(self):
        raised, nf, before, closed = in_window(
            [issue(1, "tooling", "2026-09-22T10:00:00Z")],
            [issue(2, "documentation", "2026-09-23T10:00:00Z", closed="2026-09-24T10:00:00Z")],
            self.START)
        self.expect("both are raised", [1, 2], [n for n, _ in raised])
        self.expect("both are non-functional", [1, 2], [n for n, _ in nf])
        self.expect("and the one closed in the week is closed", [2], [n for n, _ in closed])

    def test_non_functional_means_tooling_and_documentation(self):
        _, nf, _, _ = in_window([issue(1, "functional", "2026-09-22T10:00:00Z"),
                                 issue(2, "non-functional", "2026-09-22T10:00:00Z"),
                                 issue(3, None, "2026-09-22T10:00:00Z"),
                                 issue(4, "documentation", "2026-09-22T10:00:00Z")], [], self.START)
        # docs/3.7: "the count is Type of change tooling and documentation".
        self.expect("only those two types", [4], [n for n, _ in nf])

    def test_the_week_before_is_the_seven_days_before_the_window(self):
        _, _, before, _ = in_window([issue(1, "tooling", "2026-09-14T00:00:00Z"),
                                     issue(2, "tooling", "2026-09-20T23:59:00Z"),
                                     issue(3, "tooling", "2026-09-13T23:59:00Z")], [], self.START)
        self.expect("the 14th and the 20th, not the 13th", 2, before)

    def test_an_old_issue_closed_before_the_window_is_not_closed_in_it(self):
        _, _, _, closed = in_window([], [issue(5, "tooling", "2026-08-01T00:00:00Z",
                                               closed="2026-09-01T00:00:00Z")], self.START)
        self.expect("not listed", [], closed)


class WhatIsNotDerived(Cases):
    def test_an_unwritten_judgement_says_so_and_never_claims_nothing(self):
        self.expect("an unwritten section says so", True, "was not written" in render(digest()))
        self.expect("and does not claim there was nothing", False, "nothing to report" in render(digest()))
        written = render(digest(), ["I left status.sh alone"])
        self.expect("a supplied judgement is shown", True, "I left status.sh alone" in written)
        self.expect("and the disclaimer goes away", False, "was not written" in written)

    # D54: "removing tooling is as much in scope as adding it", so a week that
    # removed nothing must say so.
    def test_deletion_is_reported_even_when_it_is_zero(self):
        plain = render(digest(lines_added=4174, lines_removed=334))
        self.expect("nothing removed is stated, not omitted", True, "Nothing was removed this week." in plain)
        self.expect("the line counts appear", True, "4174 lines added, 334 removed" in plain)
        self.expect("a deleted file is named", True,
                    "`scripts/old.sh`" in render(digest(files_deleted=["scripts/old.sh"])))


if __name__ == "__main__":
    unittest.main()
