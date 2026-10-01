"""does the milestone carry only work that exists?
Moved from verify.sh's check_milestone, which is retired with this file's
first half; the second half pins the git side, which is new.

**Two halves because the check has two halves.** What a count *means* is the
board's question and is tested against fixtures; what counts as a mention is
git's, and is tested against a real history built in a temporary repository.
The second was where the risk was: a wrong answer there does not look wrong,
it looks like an issue nobody has written a commit for."""

import os
import subprocess
import tempfile
import unittest

from board.repo import mentions_on

from .cases import Cases

from board.model import RawIssue, RawSubIssue, classify
from board.milestone import carried, render, unbuilt

def issue(n, kind="Project", milestone="0.8.2", parent=None, subs=()):
    return classify(RawIssue(n, f"issue {n}", "OPEN", "", kind, {},
                             tuple(subs), parent, milestone, frozenset()))

# A count that only knows about the numbers it was given, so a fixture says
# exactly which issues the history names and nothing is inferred.
def counter(**named):
    return lambda n: named.get(f"n{n}", 0)



class WhatAMilestoneCarries(Cases):

    def test_an_issue_the_history_names_and_one_it_does_not(self):
        """an issue the history names, and one it does not"""
        rows = carried([issue(1), issue(2)], "0.8.2", counter(n1=3))
        self.expect("both are reported", [1, 2], [r.number for r in rows])
        self.expect("the named one is built", 3, rows[0].mentions)
        self.expect("and only the other is unbuilt", [2], [r.number for r in unbuilt(rows)])

    def test_a_parent_is_a_fact_never_a_finding(self):
        """a parent is a fact, never a finding"""
        # D51: the parent owns the requirements and the design, its packages carry the
        # commits. Owner, 2026-09-08: a parent's milestone "should be ignored".
        parent = issue(71, subs=(RawSubIssue(268, "Project"),))
        rows = carried([parent], "0.8.2", counter())
        self.expect("with no commits of its own, it is still not unbuilt", (), unbuilt(rows))
        self.expect("and it is named as a parent", True, rows[0].a_parent)
        # A project with folded requirements under it is NOT a parent -- #214 was
        # misread that way once -- so it is asked for commits like any other delivery.
        folded = issue(214, subs=(RawSubIssue(9, "Requirement"),))
        self.expect("a project with only folded requirements is a delivery", [214],
               [r.number for r in unbuilt(carried([folded], "0.8.2", counter()))])

    def test_the_rule_that_took_two_incidents_the_parent_s_commits_are_a_fact(self):
        """the rule that took two incidents: the parent's commits are a fact, not credit"""
        # #373 was split out of #297 the day after 1036e1c said `Refs #297`, and the
        # commit being deployed cannot be rewritten. Crediting the parent was tried on
        # 2026-09-10 and was wrong: #363 is delivery 2 of #301 and unstarted, and
        # #301's delivery-1 commits made it read as merged.
        package = issue(363, parent=301)
        rows = carried([package, issue(301, subs=(RawSubIssue(363, "Project"),))],
                       "0.8.2", counter(n301=7))
        by = {r.number: r for r in rows}
        self.expect("the package is still unbuilt", True, by[363].unbuilt)
        self.expect("and the parent's count is carried as the fact", (301, 7),
               (by[363].parent, by[363].parent_mentions))
        self.expect("the reader is told where they are", True,
               "parent #301 has 7" in render(rows, "0.8.2", colour=False))
        # The quiet half of the same rule: a package with commits of its own is never
        # described by its parent's, because there is nothing to explain.
        own = carried([issue(373, parent=297)], "0.8.2", counter(n373=2, n297=40))
        self.expect("a package with its own commits does not mention its parent", None,
               own[0].parent)
        # And a parent with nothing either way says only what it can say.
        orphan = carried([issue(364, parent=302)], "0.8.2", counter())
        self.expect("no commits anywhere: no parent clause", 0, orphan[0].parent_mentions)
        self.expect("rendered plainly", True,
               "no commit mentions this" in render(orphan, "0.8.2", colour=False)
               and "parent" not in render(orphan, "0.8.2", colour=False))

    def test_what_is_in_the_milestone_and_what_is_not(self):
        """what is in the milestone and what is not"""
        self.expect("another milestone is not this one's problem", (),
               carried([issue(5, milestone="1.0.0")], "0.8.2", counter()))
        self.expect("nor is an issue with no milestone at all", (),
               carried([issue(6, milestone=None)], "0.8.2", counter()))
        # Every type, not only deliveries: #380 and #379 were requirements sitting in
        # 0.8.1, which is the shape this catches.
        mixed = carried([issue(7, kind="Requirement"), issue(8, kind="Decision")],
                        "0.8.2", counter())
        self.expect("a requirement in a release milestone is checked", [7, 8],
               [r.number for r in mixed])
        # **Pull requests are not issues.** `gh issue list --milestone` never returned
        # one, and a PR carrying the milestone ships nothing of its own.
        pr = classify(RawIssue(9, "a pull request", "OPEN", "", "PullRequest", {},
                               (), None, "0.8.2", frozenset()))
        self.expect("a pull request on the milestone is not a finding", (),
               carried([pr], "0.8.2", counter()))
        # An untyped issue is classified as a Requirement so some rule owns it (#361),
        # and is still reported as untyped, because the type is the thing to fix.
        untyped = carried([issue(10, kind=None)], "0.8.2", counter(n10=1))
        self.expect("an untyped issue says so", "untyped", untyped[0].kind)

    def test_rendering(self):
        """rendering"""
        self.expect("an empty milestone says so plainly", True,
               "has no open issues" in render((), "0.8.2", colour=False))
        built = render(carried([issue(1)], "0.8.2", counter(n1=4)), "0.8.2", colour=False)
        self.expect("a built issue shows its count", True, "4 commits" in built)
        self.expect("and is not listed as unbuilt", False, "unbuilt:" in built)
        missing = render(carried([issue(1), issue(2)], "0.8.2", counter(n1=4)),
                         "0.8.2", colour=False)
        self.expect("the unbuilt are listed together, as verify.sh did", True,
               "unbuilt: #2" in missing)


class WhatCountsAsAMention(Cases):
    """Against a real history, because the answer is git's.

    Carried over from issue-mentions.test.sh. On 2026-09-21 the model matched
    case-insensitively and skipped merge commits, so two prose sentences
    counted as trailers and #362's only trailer, on a merge into a release
    branch, counted for nothing.
    """

    @classmethod
    def setUpClass(cls):
        cls._dir = tempfile.TemporaryDirectory()
        cls._was = os.getcwd()
        os.chdir(cls._dir.name)

        def git(*args):
            subprocess.run(["git", *args], check=True, capture_output=True)

        def commit(message):
            git("commit", "-q", "--allow-empty", "-m", "app 0.0.1 api 1.0: " + message)

        git("init", "-q", "-b", "main", ".")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "test")
        commit("one\n\nRefs #17")
        commit("two\n\nRefs #170")
        commit("three\n\nCloses #17")
        commit("prose only\n\nThis mentions #17 and says it now refs #17 in a sentence, which is not a\n"
               "trailer. It also says that closes #17, still in prose.\n\nRefs #99")
        git("checkout", "-q", "-b", "merged")
        commit("on a branch that lands\n\nRefs #501")
        git("checkout", "-q", "main")
        git("merge", "-q", "--no-ff", "merged", "-m", "app 0.0.1 api 1.0: merge the branch\n\nRefs #362")
        git("checkout", "-q", "-b", "unmerged")
        commit("work in progress\n\nRefs #500")
        git("checkout", "-q", "main")
        cls.scope = mentions_on("HEAD")

    @classmethod
    def tearDownClass(cls):
        os.chdir(cls._was)
        cls._dir.cleanup()

    def test_trailers(self):
        # Two trailers name #17 and two prose sentences do. Only the trailers
        # count: matching any `#N` refused the 0.7.2 release, when b231721 named
        # #224 and #241 as examples in its prose.
        self.expect("the trailer counts, the prose does not", 2, self.scope.count(17))
        self.expect("#17 is not #170-something", 1, self.scope.count(170))
        self.expect("a commit that closes is not also referencing", 1, len(self.scope.closes.get(17, [])))
        self.expect("a trailer in a body with prose still counts", 1, self.scope.count(99))

    def test_what_is_reachable(self):
        # The gate counts merges, so the pre-flight must.
        self.expect("a merge commit's trailer counts", 1, self.scope.count(362))
        self.expect("a merged branch's own commit counts too", 1, self.scope.count(501))
        self.expect("a branch not merged here is not counted", 0, self.scope.count(500))

    def test_the_gate_counts_the_same(self):
        # deploy.sh refuses on issue-mentions.sh's commits_mentioning; this
        # pre-flight reports on mentions_on. The failure nobody would see is the
        # pre-flight passing where the gate refuses, so the two are compared on
        # one history rather than read.
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "application", "deliver", "issue-mentions.sh")
        for n in (17, 99, 170, 362, 500, 501):
            gate = subprocess.run(["bash", "-c", f'source "{script}"; commits_mentioning HEAD {n}'],
                                  capture_output=True, text=True).stdout.strip()
            self.expect(f"#{n}", str(self.scope.count(n)), gate)


if __name__ == "__main__":
    unittest.main()
