"""R2's grouping and event rules, on fixtures.

The fetching is not tested here; it is `gh` and a live board. What is tested
is the part that used to be spread through `inbox.sh`'s awk and shell: which
remark belongs to which issue, who is held to have typed it, and what counts
as opened or closed inside the window."""

import unittest

from .cases import Cases

from board.inbox import build, render
from board.model import RawIssue
from board.sources import Remark, Report

def issue(n, title="t", created=None, closed=None, state="OPEN"):
    return RawIssue(n, title, state, "", "Requirement", {}, (), None, None,
                    frozenset(), frozenset(), frozenset(),
                    created_at=created, closed_at=closed)

SINCE = "2026-09-14T00:00:00Z"



class TheInbox(Cases):

    def test_grouping(self):
        """grouping"""
        remarks = (
            Remark(7, "2026-09-15T09:00", "owner", "a question", False),
            Remark(7, "2026-09-15T10:00", "claude", "an answer", False),
            Remark(9, "2026-09-16T09:00", "deploy", "Released in prod-0.8.1", False),
        )
        inbox = build([issue(7, "seven"), issue(9, "nine")], remarks, SINCE)
        self.expect("a thread per issue", 2, len(inbox.threads))
        self.expect("remarks stay with their issue", 2, len(inbox.threads[0].remarks))
        self.expect("the owner's are counted", 1, inbox.from_owner)

    def test_a_remark_on_an_issue_the_snapshot_does_not_hold_still_arrives(self):
        """a remark on an issue the snapshot does not hold still arrives"""
        # Something said on an issue outside the window's board is still something said.
        inbox = build([], (Remark(404, "2026-09-15T09:00", "owner", "hello", False),), SINCE)
        self.expect("the thread exists", 1, len(inbox.threads))
        self.expect("with no title rather than being dropped", "", inbox.threads[0].title)

    def test_opened_closed_and_both(self):
        """opened, closed, and both"""
        # **Opened *and* closed inside the window needs saying.** Reporting only
        # "opened" reads as still-open, which after a week away is the one thing
        # somebody would act on wrongly.
        issues = [
            issue(1, "opened only", created="2026-09-15T00:00:00Z"),
            issue(2, "closed only", created="2026-09-01T00:00:00Z", closed="2026-09-15T00:00:00Z"),
            issue(3, "both", created="2026-09-15T00:00:00Z", closed="2026-09-16T00:00:00Z"),
            issue(4, "neither", created="2026-09-01T00:00:00Z"),
        ]
        inbox = build(issues, (), SINCE)
        self.expect("three events, not four", 3, len(inbox.events))
        self.expect("opened", "opened", inbox.events[0].what)
        self.expect("closed", "closed", inbox.events[1].what)
        self.expect("both is said as both", "opened+closed", inbox.events[2].what)

    def test_rendering(self):
        """rendering"""
        out = render(build([issue(7, "seven")],
                           (Remark(7, "2026-09-15T09:00", "owner", "mine", False),),
                           SINCE), colour=False)
        self.expect("the owner's remark is marked", True, "> 2026-09-15T09:00  mine" in out)
        self.expect("a quiet window says so", True,
              "nothing opened or closed" in render(build([], (), SINCE), colour=False))


class WhoTypedIt(Cases):
    """sources.comment_jq, run through the real jq on canned comments. The rule
    lived untested in a string, which is how a bot's comment read as the
    owner's until 2026-09-27."""

    def who(self, login, kind, body="a comment"):
        import json, shutil, subprocess
        if not shutil.which("jq"):
            self.skipTest("jq is not installed")
        from board.sources import comment_jq
        comment = [{"issue_url": "https://api.github.com/repos/o/r/issues/7", "updated_at": "2026-09-27T10:00:00Z",
                    "user": {"login": login, "type": kind}, "body": body}]
        out = subprocess.run(["jq", "-r", comment_jq("issue_url")], input=json.dumps(comment),
                             capture_output=True, text=True, check=True).stdout
        return out.split("\t")[2]

    def test_each_account_is_read_as_what_it_is(self):
        self.expect("the owner", "owner", self.who("SteveStyle", "User"))
        self.expect("Claude", "claude", self.who("SteveStyle-typed-by-Claude", "User"))
        self.expect("a workflow", "bot", self.who("github-actions[bot]", "Bot"))
        self.expect("Dependabot", "bot", self.who("dependabot[bot]", "Bot"))
        self.expect("deploy.sh's announcement", "deploy",
                    self.who("SteveStyle-typed-by-Claude", "User", "Released in prod-0.9.0"))


class Reports(Cases):
    """Owner, 2026-09-27: "can you add a hook so you notice a new report?" The
    workflows report by writing an issue, which leaves no comment behind."""

    def test_a_bot_is_not_the_owner(self):
        # Everything not Claude's account was the owner's until 2026-09-27.
        inbox = build([issue(393)], (Remark(393, "2026-09-19T10:00", "bot", "Dependabot will rebase", False),), SINCE)
        self.expect("a bot's comment is not counted as his", 0, inbox.from_owner)
        self.expect("and is shown as a bot's", True, "[bot] Dependabot will rebase" in render(inbox, colour=False))

    def test_a_report_has_its_own_section(self):
        inbox = build([], (), SINCE, (Report(384, "Dependency advisories need review", "OPEN", "2026-09-19T19:36"),))
        text = render(inbox, colour=False)
        self.expect("under its heading", True, "REPORTS FROM THE SCHEDULED WORKFLOWS" in text)
        self.expect("named, with its state", True, "#384   open" in text and "Dependency advisories" in text)

    def test_a_cleared_report_is_news_too(self):
        text = render(build([], (), SINCE, (Report(384, "advisories", "CLOSED", "2026-09-20T06:15"),)), colour=False)
        self.expect("a closed report is listed as closed", True, "#384   closed" in text)

    def test_no_report_says_so(self):
        text = render(build([], (), SINCE), colour=False)
        self.expect("rather than an empty heading", True, "no report opened, updated or closed" in text)


if __name__ == "__main__":
    unittest.main()

