"""R9, folded in from #342.

The relationship, not the naming. `.githooks/commit-msg` already compares the
branch name against the commit trailer; what it cannot do is ask whether the
issue they agree on is real, open, and a project. These are those three."""

import unittest

from .cases import Cases

from board.branches import check, render
from board.model import RawIssue

def issue(n, kind="Project", state="OPEN"):
    return RawIssue(n, f"issue {n}", state, "", kind, {}, (), None, None,
                    frozenset(), frozenset(), frozenset())

board = {
    214: issue(214),
    290: issue(290),
    342: issue(342, kind="Requirement"),
    395: issue(395, state="CLOSED"),
}

from board.branches import named_numbers


class BranchesAndTheIssuesTheyName(Cases):

    def test_a_branch_naming_an_open_project_is_fine(self):
        """a branch naming an open project is fine"""
        self.expect("no finding", 0, len(check(["214-build-once"], board)))
        self.expect("nor for the older issue- form", 0, len(check(["issue-290-dioxus"], board)))

    def test_and_the_three_that_are_not(self):
        """and the three that are not"""
        f = check(["999-invented"], board)
        self.expect("an issue that does not exist", 1, len(f))
        self.expect("says so", True, "does not exist" in f[0].says)

        f = check(["395-packages"], board)
        self.expect("a closed project", 1, len(f))
        self.expect("says to delete it once its release shipped", True, "closed" in f[0].says)

        f = check(["342-branch-check"], board)
        self.expect("a requirement rather than a project", 1, len(f))
        self.expect("cites the rule", True, "docs/3.6" in f[0].says)

    def test_what_is_deliberately_not_a_finding(self):
        """what is deliberately not a finding"""
        # A rule about naming would refuse these, and #342 is about the relationship.
        self.expect("main", 0, len(check(["main"], board)))
        self.expect("a release branch", 0, len(check(["release/0.8.1"], board)))
        self.expect("a branch naming no issue at all", 0, len(check(["spike-wasm-sizes"], board)))

    def test_named_numbers_which_lets_a_caller_fetch_only_what_it_needs(self):
        """named_numbers, which lets a caller fetch only what it needs"""
        self.expect("the numbers, deduplicated and sorted", (214, 290),
               named_numbers(["290-dioxus-07", "214-build-once", "214-again"]))
        self.expect("main and release branches are not numbers", (),
               named_numbers(["main", "release/0.8.1", "spike"]))

    def test_rendering(self):
        """rendering"""
        self.expect("a clean run says how many it looked at", True,
               "2 branch(es)" in render((), 2, colour=False))
        self.expect("a finding names the branch", True,
               "999-invented" in render(check(["999-invented"], board), 1, colour=False))


if __name__ == "__main__":
    unittest.main()

