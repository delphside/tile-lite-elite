"""The weekly digest, the `weekly-digest` activity in docs/3.8.

From docs/3.7's brake, not from the code. The cases that matter are the ones
where a bug would flatter the report or repeat a settled question:

  the measure     programme overhead raised per week (types `tooling` and
                  `documentation`, not the type called `non-functional`),
                  beside the week before; every other type counted with its
                  reading; and what is waiting on the owner. Owner, 2026-09-21
                  and 2026-09-27.
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

from board.digest import Digest, Window, in_window, render, MEASURED_AT
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
    def test_overhead_raised_and_closed_is_counted_beside_the_week_before(self):
        w = Window(overhead=[(401, "a tooling fix")],
                   closed_by_type=collections.Counter({"tooling": 2, "bug": 9}),
                   raised_before=collections.Counter({"tooling": 2, "documentation": 1, "bug": 5}),
                   closed_before=collections.Counter({"documentation": 4}))
        text = render(digest(window=w))
        self.expect("raised and closed this week, overhead only", True,
                    "**1** programme overhead issues raised (`tooling` or `documentation`) and **2** closed" in text)
        self.expect("beside the week before", True, "against **3** raised and **4** closed in the seven days before" in text)
        self.expect("and each is named", True, "#401 a tooling fix" in text)

    def test_every_type_is_counted_raised_closed_and_open_with_its_reading(self):
        w = Window(raised_by_type=collections.Counter({"functional": 4, "bug": 1}),
                   closed_by_type=collections.Counter({"bug": 2}),
                   raised_before=collections.Counter({"bug": 3}),
                   closed_before=collections.Counter({"functional": 1}))
        d = digest(window=w)
        d.by_type = collections.Counter({"functional": 10, "bug": 2})
        text = render(d)
        # Owner, 2026-09-27: this week raised, closed, open; then last week the same.
        self.expect("grouped by week", True,
                    "| type of change | this week: raised | closed | open | last week: raised | closed | open | reads as |" in text)
        self.expect("functional", True, "| `functional` | 4 | 0 | 10 | 0 | 1 | 0 | the most constructive use of your time |" in text)
        self.expect("bugs", True, "| `bug` | 1 | 2 | 2 | 3 | 0 | 0 | not constructive" in text)
        # A quiet type still gets its row, so a week with no bugs is visible.
        self.expect("a type with nothing is still shown", True, "| `documentation` | 0 | 0 | 0 | 0 | 0 | 0 |" in text)
        # Owner, 2026-09-27: cosmetic is counted separately and credited as functional.
        self.expect("cosmetic reads as functional", True,
                    "| `cosmetic` | 0 | 0 | 0 | 0 | 0 | 0 | counted separately, credited as functional |" in text)
        odd = render(digest(window=Window(raised_by_type=collections.Counter({"spike": 1}))))
        self.expect("a type docs/3.7 does not name is shown, not dropped", True,
                    "| `spike` | 1 | 0 | 0 | 0 | 0 | 0 | not in docs/3.7 |" in odd)

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
        w = in_window([issue(1, "tooling", "2026-09-22T10:00:00Z")],
                      [issue(2, "documentation", "2026-09-23T10:00:00Z", closed="2026-09-24T10:00:00Z")],
                      self.START)
        self.expect("both are raised", [1, 2], [n for n, _ in w.raised])
        self.expect("both are overhead", [1, 2], [n for n, _ in w.overhead])
        self.expect("and the one closed in the week is closed", [2], [n for n, _ in w.closed])
        self.expect("counted by its type", {"documentation": 1}, dict(w.closed_by_type))

    def test_overhead_means_tooling_and_documentation_not_the_type_called_non_functional(self):
        w = in_window([issue(1, "functional", "2026-09-22T10:00:00Z"),
                                                issue(2, "non-functional", "2026-09-22T10:00:00Z"),
                                                issue(3, None, "2026-09-22T10:00:00Z"),
                                                issue(4, "documentation", "2026-09-22T10:00:00Z")], [], self.START)
        # docs/3.7, owner 2026-09-27: the overhead is tooling and documentation.
        self.expect("only those two types", [4], [n for n, _ in w.overhead])
        self.expect("every type is still counted", {"functional": 1, "non-functional": 1, "unset": 1, "documentation": 1},
                    dict(w.raised_by_type))

    def test_the_week_before_is_the_seven_days_before_the_window(self):
        w = in_window([issue(1, "tooling", "2026-09-14T00:00:00Z"),
                       issue(2, "bug", "2026-09-20T23:59:00Z"),
                       issue(3, "tooling", "2026-09-13T23:59:00Z")],
                      [issue(4, "bug", "2026-08-01T00:00:00Z", closed="2026-09-15T00:00:00Z"),
                       issue(5, "bug", "2026-08-01T00:00:00Z", closed="2026-09-13T00:00:00Z")], self.START)
        self.expect("raised on the 14th and the 20th, not the 13th", {"tooling": 1, "bug": 1}, dict(w.raised_before))
        self.expect("closed on the 15th, not the 13th", {"bug": 1}, dict(w.closed_before))

    def test_open_last_week_reconciles_with_open_now(self):
        # Open at the end of last week, plus raised, less closed, is open now:
        # the check that both open counts mean what they say.
        open_now = [issue(1, "bug", "2026-09-01T00:00:00Z"), issue(2, "bug", "2026-09-22T00:00:00Z")]
        closed = [issue(3, "bug", "2026-09-02T00:00:00Z", closed="2026-09-23T00:00:00Z"),
                  issue(4, "bug", "2026-09-02T00:00:00Z", closed="2026-09-10T00:00:00Z"),
                  issue(5, "bug", "2026-09-22T00:00:00Z", closed="2026-09-24T00:00:00Z")]
        w = in_window(open_now, closed, self.START)
        self.expect("open at the end of last week: #1 and #3, not #4 closed before it", 2, w.open_before["bug"])
        self.expect("reconciles: 2 + 2 raised - 2 closed = 2 open now", len(open_now),
                    w.open_before["bug"] + w.raised_by_type["bug"] - w.closed_by_type["bug"])

    def test_an_old_issue_closed_before_the_window_is_not_closed_in_it(self):
        w = in_window([], [issue(5, "tooling", "2026-08-01T00:00:00Z", closed="2026-09-01T00:00:00Z")], self.START)
        self.expect("not listed", [], w.closed)
        self.expect("nor counted", 0, sum(w.closed_by_type.values()))


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
