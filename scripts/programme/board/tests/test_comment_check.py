"""#454 R5: the check before Claude comments, on a stub in place of GitHub.

What is tested is which commands it reacts to and what it says. Whether an
issue has unanswered comments is `test_inbox.py`'s."""

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from .cases import Cases

HOOK = Path(__file__).resolve().parents[4] / ".claude" / "comment-check.sh"


class BeforeCommenting(Cases):

    def run_hook(self, command, open_lines):
        with tempfile.TemporaryDirectory() as d:
            stub = Path(d) / "inbox"
            body = "\n".join(f"echo '{line}'" for line in open_lines) or "echo 'nothing from the owner is waiting for an answer'"
            stub.write_text(f"#!/bin/sh\n{body}\n")
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            return subprocess.run([str(HOOK)], input=json.dumps({"tool_input": {"command": command}}),
                                  capture_output=True, text=True,
                                  env={**os.environ, "COMMENT_CHECK_INBOX": str(stub)}).stdout

    ASK = ["#7  seven", "  > 2026-10-01T09:00  a question"]

    def test_it_speaks_when_a_comment_is_about_to_be_posted(self):
        for command in ("gh issue comment 7 --body hi",
                        "gh issue comment #7 --body-file /tmp/x",
                        "gh api repos/o/r/issues/7/comments -f body=x",
                        "gh issue close 7 --comment done",
                        "cd x && gh issue comment 7 -F y"):
            out = self.run_hook(command, self.ASK)
            self.expect(command, True, "a question" in out and "#7 has comments" in out)

    def test_it_says_it_as_context_and_never_blocks(self):
        out = json.loads(self.run_hook("gh issue comment 7 --body hi", self.ASK))
        self.expect("the event", "PreToolUse", out["hookSpecificOutput"]["hookEventName"])
        self.expect("no decision is made", False, "permissionDecision" in out["hookSpecificOutput"])

    def test_it_is_silent_otherwise(self):
        self.expect("a close with no comment", "", self.run_hook("gh issue close 7", self.ASK))
        self.expect("a read", "", self.run_hook("gh issue view 7", self.ASK))
        self.expect("an unrelated command", "", self.run_hook("ls -l", self.ASK))
        self.expect("nothing waiting", "", self.run_hook("gh issue comment 7 --body hi", []))
        self.expect("no input at all", "", subprocess.run([str(HOOK)], input="", capture_output=True, text=True).stdout)


if __name__ == "__main__":
    unittest.main()
