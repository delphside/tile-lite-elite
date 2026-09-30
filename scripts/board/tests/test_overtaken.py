"""a shipped project still open when the next release
went out. Moved from verify.sh's check_reviews.

The rule that matters is which clock: entering Post-deployment, not the phase
it sits in now. A project that wrote its review promptly and then sat unclosed
for a month has still been open a month."""

import unittest

from .cases import Cases

from board.model import RawIssue, classify
from board.overtaken import candidates, check, render

def proj(n, phase, parent=None):
    return classify(RawIssue(n, f"project {n}", "OPEN", "", "Project",
                             {"Project State": phase, "Route": "Production Release"},
                             (), parent, None, frozenset()))

RELEASE = 1_000_000.0
BEFORE, AFTER = RELEASE - 86_400, RELEASE + 86_400

issues = [proj(1, "Post-deployment", parent=9), proj(2, "Project Closedown", parent=9),
          proj(3, "Development", parent=9), proj(4, "Scope", parent=9)]




class Overtaken(Cases):

    def test_which_projects_are_worth_dating(self):
        """which projects are worth dating"""

        self.expect("both shipped phases, and no others", [1, 2],
               [i.number for i in candidates(issues)])

    def test_the_clock_is_entering_post_deployment(self):
        """the clock is entering Post-deployment"""
        # #2 is at Project Closedown now; what counts is when it shipped.
        found = check(issues, {1: AFTER, 2: BEFORE}, RELEASE)
        self.expect("one overtaken", [2], [o.number for o in found])
        self.expect("and it is named at the phase it sits in now", "Project Closedown",
               found[0].step)

    def test_what_is_deliberately_not_a_finding(self):
        """what is deliberately not a finding"""
        self.expect("no release yet, so nothing can have been overtaken", 0,
               len(check(issues, {1: BEFORE, 2: BEFORE}, None)))
        # Set before the field existed, or moved by a migration. Unknown must not read
        # as late.
        self.expect("a project with no date at all", 0, len(check(issues, {}, RELEASE)))
        self.expect("one that shipped after the release", 0,
               len(check(issues, {1: AFTER, 2: AFTER}, RELEASE)))

    def test_rendering(self):
        """rendering"""
        self.expect("a clean run says so", True,
               "nothing shipped past" in render((), colour=False))
        self.expect("a finding names the issue", True,
               "#2" in render(check(issues, {2: BEFORE}, RELEASE), colour=False))


if __name__ == "__main__":
    unittest.main()

