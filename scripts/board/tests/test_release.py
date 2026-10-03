"""what a milestone still owes, moved from verify.sh's
check_approach.

A release question rather than a per-issue one: board-check.py's obligations
ask whether a delivery owes a test approach at its step; this asks whether the
tests the projects in *this release* said they would run have been run."""

import unittest

from .cases import Cases

from board.model import RawIssue, RawSubIssue, classify
from board.release import outstanding, render

APPROACH = """## Test approach

### Functional user tests — Preview

%s

### Technical tests — Rehearsal

%s
"""

def wp(n, preview, rehearsal, milestone="0.8.2", subs=()):
    return classify(RawIssue(n, f"wp {n}", "OPEN", APPROACH % (preview, rehearsal),
                             "Project", {"Phase": "Development", "Route": "x"},
                             subs, 9 if not subs else None, milestone, frozenset()))

done = wp(1, "- [x] **Claude** — looked at it", "- [x] **Claude** — ran it")
half = wp(2, "- [ ] **owner** — not looked at", "- [x] **Claude** — ran it")




class TheRelease(Cases):

    def test_what_is_outstanding(self):
        """what is outstanding"""

        self.expect("everything ticked is not reported", 0, len(outstanding([done], "0.8.2")))
        found = outstanding([half], "0.8.2")
        self.expect("one unticked box is", 1, len(found))
        self.expect("counted on the right side", (1, 0), (found[0].preview, found[0].rehearsal))

    def test_a_project_with_no_headings_at_all(self):
        """a project with no headings at all"""
        bare = classify(RawIssue(3, "bare", "OPEN", "## Design\n", "Project",
                                 {"Phase": "Development", "Route": "x"}, (), 9,
                                 "0.8.2", frozenset()))
        found = outstanding([bare], "0.8.2")
        self.expect("is reported", 1, len(found))
        self.expect("and told apart from one that said and has not", True,
               found[0].missing_headings)

    def test_what_is_deliberately_skipped(self):
        """what is deliberately skipped"""
        # D51: the packages own the test approach, so naming the parent is a finding
        # nobody can clear.
        parent = wp(4, "- [ ] **owner** — unticked", "- [ ] **Claude** — unticked",
                    subs=(RawSubIssue(5, "Project"),))
        self.expect("a parent", 0, len(outstanding([parent], "0.8.2")))
        self.expect("another milestone", 0, len(outstanding([half], "0.9.0")))
        decision = classify(RawIssue(6, "d", "OPEN", "", "Decision",
                                     {"Decision State": "Asked"}, (), None, None,
                                     frozenset()))
        # A Decision carries no milestone attribute at all, so the type is tested first.
        self.expect("a decision, without raising", 0, len(outstanding([decision], "0.8.2")))

    def test_carried_over_from_verify_test_approach_test_sh_which_this_retires(self):
        """carried over from verify-test-approach.test.sh, which this retires"""
        # **An unticked post-deployment row is not a test nobody has run.** It is a
        # check nobody has answered yet, and counting it here would fail every project
        # the moment it shipped. The sections are scoped for exactly this.
        mixed = classify(RawIssue(7, "mixed", "OPEN",
            APPROACH % ("- [x] **owner** — looked", "- [x] **Claude** — ran")
            + "\n## Post-deployment checks against requirements\n\n"
              "- [ ] **owner** — did the benefit arrive\n",
            "Project", {"Phase": "Post-deployment", "Route": "x"}, (), 9, "0.8.2",
            frozenset()))
        self.expect("an unticked post-deployment box is not a test", 0,
               len(outstanding([mixed], "0.8.2")))
        # The quiet case a broken check passes by accident, so it is here twice.
        self.expect("a milestone with no projects at all", 0, len(outstanding([], "0.8.2")))

    def test_rendering(self):
        """rendering"""
        self.expect("clean says so", True, "nothing outstanding" in render((), "0.8.2", colour=False))
        self.expect("a finding counts both sides", True,
               "1 on Preview, 0 on Rehearsal" in render(outstanding([half], "0.8.2"),
                                                        "0.8.2", colour=False))


if __name__ == "__main__":
    unittest.main()

