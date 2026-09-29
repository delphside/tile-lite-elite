"""What a merge into main moves on the board: which issue it delivered, and
where its Phase goes. On canned issues, with no network. The hook's half, that
it fires for `git merge <N-branch>` on main and nothing else, is
`scripts/tests/post-merge-hook.bats`.
"""

import unittest

from board.merge import moves, named, next_phase
from board.model import RawIssue, RawSubIssue, classify

from .cases import Cases


def issue(n, phase=None, route=None, parent=None, subs=(), kind="Project", state="OPEN"):
    fields = {k: v for k, v in (("Phase", phase), ("Route", route)) if v}
    return classify(RawIssue(n, f"#{n}", state, "", kind, fields, tuple(subs), parent, None, frozenset()))


def wp(phase, route="Production Release", **k):
    return issue(414, phase, route, parent=400, **k)


PARENT = issue(400, "Scope", subs=[RawSubIssue(414, "Project"), RawSubIssue(415, "Project")])


class WhatAMergeMoves(Cases):
    def test_which_issue_a_merge_delivered(self):
        self.expect("the pull request names the package the branch does not",
                    [400, 414], named("400-scheduler-mechanism", "#414 Scheduler core", "Refs #414, `#400 WP A`."))
        self.expect("a branch with no pull request still names itself", [415], named("415-x"))

    def test_where_its_phase_goes(self):
        self.expect("an image change in user testing goes to Deployment", "Deployment", next_phase(wp("User testing")))
        self.expect("so does one merged straight from Development", "Deployment", next_phase(wp("Development")))
        # The Repository Change route split in two (owner, 2026-09-29, #421
        # R4); a merge delivers both, and the deprecated option, under
        # whatever name it now carries, is history that behaves as it did.
        for route in ("Application Tooling and Docs", "Programme Tooling and Docs",
                      "Repository Change", "Repository Change DEPRECATED"):
            self.expect(f"a merge delivers {route}", "Post-deployment",
                        next_phase(wp("User testing", route)))

    def test_what_is_left_alone(self):
        self.expect("a Phase already past the merge is left alone", None, next_phase(wp("Deployment")))
        self.expect("nothing moves backwards", None, next_phase(wp("Post-deployment")))
        self.expect("an Other route has no merge to complete", None, next_phase(wp("User testing", "Other")))
        self.expect("a closed package is left alone", None, next_phase(wp("User testing", state="CLOSED")))
        self.expect("a parent does not deliver", None, next_phase(PARENT))
        self.expect("a requirement has no Phase to move", None,
                    next_phase(issue(418, "User testing", "Repository Change", kind="Requirement")))

    def test_the_414_case(self):
        self.expect("the parent named by the branch is skipped, the package moved",
                    [(414, "User testing", "Deployment")], moves([400, 414], {400: PARENT, 414: wp("User testing")}))


if __name__ == "__main__":
    unittest.main()
