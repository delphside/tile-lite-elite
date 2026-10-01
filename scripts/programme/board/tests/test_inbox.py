"""R2's grouping and event rules, on fixtures.

The fetching is not tested here; it is `gh` and a live board. What is tested
is the part that used to be spread through `inbox.sh`'s awk and shell: which
remark belongs to which issue, who is held to have typed it, and what counts
as opened or closed inside the window."""

import unittest

from .cases import Cases

from board.inbox import build, render, render_waiting, unanswered, waiting_for_claude
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


def say(n, when, who, text="a comment", created=None):
    return Remark(n, when, who, text, False, created or when + ":00")


class WaitingForClaude(Cases):
    """#454. The rules, as the owner stated them on 2026-10-01: a comment of his
    is open until a later comment from Claude on the same issue, automatic
    comments do not count as an answer, and there is no time limit."""

    def test_unanswered_and_answered(self):
        self.expect("a question alone is open", 1,
                    len(unanswered((say(7, "2026-10-01T09:00", "owner"),))))
        self.expect("a later answer closes it", 0, len(unanswered((
            say(7, "2026-10-01T09:00", "owner"), say(7, "2026-10-01T10:00", "claude")))))
        self.expect("an answer before the question does not", 1, len(unanswered((
            say(7, "2026-10-01T08:00", "claude"), say(7, "2026-10-01T09:00", "owner")))))
        self.expect("an answer on another issue does not", 1, len(unanswered((
            say(7, "2026-10-01T09:00", "owner"), say(8, "2026-10-01T10:00", "claude")))))

    def test_a_reply_in_the_same_second_counts_as_an_answer(self):
        self.expect("nothing can order them", 0, len(unanswered((
            say(7, "2026-10-01T09:00", "owner"), say(7, "2026-10-01T09:00", "claude")))))

    def test_asked_again_after_an_answer(self):
        got = unanswered((say(7, "2026-10-01T09:00", "owner", "first"),
                          say(7, "2026-10-01T10:00", "claude"),
                          say(7, "2026-10-01T11:00", "owner", "second")))
        self.expect("only the later one is open", ["second"], [r.text for r in got])

    def test_an_automatic_comment_is_not_an_answer(self):
        for who in ("deploy", "bot"):
            self.expect(f"{who} after a question", 1, len(unanswered((
                say(7, "2026-10-01T09:00", "owner"), say(7, "2026-10-01T10:00", who)))))

    def test_there_is_no_time_limit(self):
        self.expect("a year-old question is still open", 1,
                    len(unanswered((say(7, "2025-10-01T09:00", "owner"),))))

    def test_an_edit_does_not_reopen_an_answered_comment(self):
        # `when` is the updated time; the order is by when each was first written.
        owner = say(7, "2026-10-02T09:00", "owner", created="2026-10-01T09:00:00")
        claude = say(7, "2026-10-01T10:00", "claude")
        self.expect("an edited question is still answered", 0, len(unanswered((owner, claude))))

    def test_a_closed_issue_or_merged_pull_request_has_nothing_waiting(self):
        r = (say(7, "2026-10-01T09:00", "owner"), say(8, "2026-10-01T09:00", "owner"),
             say(9, "2026-10-01T09:00", "owner"))
        issues = [issue(7, state="OPEN"), issue(8, state="CLOSED"), issue(9, state="MERGED")]
        self.expect("only the open one", [7], [t.number for t in waiting_for_claude(issues, r)])

    def test_newest_last_and_capped_with_a_count(self):
        threads = waiting_for_claude(
            [issue(n) for n in range(1, 16)],
            tuple(say(n, f"2026-10-01T{n:02d}:00", "owner", f"q{n}") for n in range(1, 16)))
        self.expect("oldest first, newest last", [1, 15], [threads[0].number, threads[-1].number])
        text = render_waiting(threads, colour=False)
        self.expect("twelve shown", 12, text.count("\n  > ") + (1 if text.startswith("  > ") else 0))
        self.expect("the count of the rest is said", True, "...3 earlier" in text)
        self.expect("uncapped on request", False, "earlier" in render_waiting(threads, colour=False, limit=99))

    def test_each_shows_the_first_words(self):
        text = render_waiting(waiting_for_claude(
            [issue(7, "seven")], (say(7, "2026-10-01T09:00", "owner", "x" * 400),)), colour=False)
        self.expect("cut at 120 characters", True, "x" * 120 in text and "x" * 121 not in text)

    def test_nothing_waiting_says_so(self):
        self.expect("a sentence, not an empty list", "nothing from the owner is waiting for an answer",
                    render_waiting((), colour=False))


class WhoTypedIt(Cases):
    """sources.comment_jq, run through the real jq on canned comments. The rule
    lived untested in a string, which is how a bot's comment read as the
    owner's until 2026-09-27."""

    def who(self, login, kind, body="a comment"):
        import json, shutil, subprocess
        if not shutil.which("jq"):
            self.skipTest("jq is not installed")
        from board.sources import comment_jq
        comment = [{"issue_url": "https://api.github.com/repos/o/r/issues/7", "updated_at": "2026-09-27T10:00:00Z", "created_at": "2026-09-26T08:00:00Z",
                    "user": {"login": login, "type": kind}, "body": body}]
        out = subprocess.run(["jq", "-r", comment_jq("issue_url")], input=json.dumps(comment),
                             capture_output=True, text=True, check=True).stdout
        return out.split("\t")[2]

    def test_the_row_carries_when_it_was_first_written(self):
        import json, shutil, subprocess
        if not shutil.which("jq"):
            self.skipTest("jq is not installed")
        from board.sources import comment_jq
        c = [{"issue_url": "https://x/issues/7", "updated_at": "2026-09-27T10:00:00Z",
              "created_at": "2026-09-26T08:00:05Z", "user": {"login": "u", "type": "User"}, "body": "b"}]
        row = subprocess.run(["jq", "-r", comment_jq("issue_url")], input=json.dumps(c),
                             capture_output=True, text=True, check=True).stdout.rstrip("\n").split("\t")
        self.expect("a fifth column, to the second", "2026-09-26T08:00:05", row[4])

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

