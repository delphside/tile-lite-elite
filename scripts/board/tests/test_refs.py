"""Which issue a commit, a pull request or a branch names.

The rule has one owner, `board/refs.py`; until 2026-09-26 it had six copies
that disagreed (#421). The cases are the rule's own, from
`issue-mentions.sh`'s measured decision: the capitalised trailer counts, and
prose does not. The second half runs `board-refs.py` against a real history,
because that command is what the hooks and deploy.sh ask.
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

from board import refs

from .cli import run


class AMessage(unittest.TestCase):
    def test_refs_and_closes_both_name(self):
        self.assertEqual({12, 34}, refs.named("fix it\n\nRefs #12\nCloses #34"))

    def test_only_closes_closes(self):
        self.assertEqual({34}, refs.closes("Refs #12\nCloses #34"))

    def test_prose_in_lower_case_is_not_a_trailer(self):
        self.assertEqual(set(), refs.named("this closes #103 eventually, refs #9"))

    def test_githubs_other_keywords_are_not_ours(self):
        self.assertEqual(set(), refs.named("Fixes #5\nResolves #6"))

    def test_a_colon_is_not_our_form(self):
        self.assertEqual(set(), refs.named("Refs: #7"))

    def test_a_longer_number_is_not_a_shorter_one(self):
        self.assertEqual({1234}, refs.named("Refs #1234"))


class APullRequest(unittest.TestCase):
    def test_the_titles_leading_number(self):
        self.assertEqual({414}, refs.pull_request_names("#414 Scheduler core", ""))

    def test_and_the_bodys_trailers(self):
        self.assertEqual({414, 400}, refs.pull_request_names("#414 Scheduler core", "Refs #400."))

    def test_a_number_later_in_the_title_is_not_the_lead(self):
        self.assertEqual(set(), refs.pull_request_names("fix for #12", ""))


class ABranch(unittest.TestCase):
    def test_n_name(self):
        self.assertEqual(415, refs.branch_issue("415-admin-cli"))

    def test_the_older_issue_n_name(self):
        self.assertEqual(214, refs.branch_issue("issue-214-build-once"))

    def test_a_remote_tracking_name(self):
        self.assertEqual(415, refs.branch_issue("origin/415-admin-cli"))

    def test_an_unnumbered_branch(self):
        self.assertIsNone(refs.branch_issue("tidy-up"))

    def test_main(self):
        self.assertIsNone(refs.branch_issue("main"))


class TheCommandAgainstARealHistory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._dir = tempfile.TemporaryDirectory()
        repo = cls.repo = Path(cls._dir.name)

        def git(*args):
            subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@e", "-c", "user.name=t", *args],
                           check=True, capture_output=True)

        git("init", "-q", "-b", "main")
        for message in ("base", "one\n\nRefs #7", "two, which closes #7 in passing\n\nCloses #8"):
            git("commit", "-q", "--allow-empty", "-m", message)
        git("tag", "mid")
        git("commit", "-q", "--allow-empty", "-m", "three\n\nRefs #7\nRefs #9")
        git("checkout", "-q", "-b", "side", "mid")
        git("commit", "-q", "--allow-empty", "-m", "side work")
        git("checkout", "-q", "main")
        git("merge", "-q", "--no-ff", "side", "-m", "merge side\n\nRefs #11")

    @classmethod
    def tearDownClass(cls):
        cls._dir.cleanup()

    def refs(self, *args, stdin=""):
        return run("board-refs.py", "-C", str(self.repo), *args, stdin=stdin)

    def test_count_commits_naming_7_not_the_prose_in_8s_commit(self):
        self.assertEqual("2", self.refs("count", "main", "7").stdout.strip())

    def test_count_a_merges_trailer_counts(self):
        self.assertEqual("1", self.refs("count", "main", "11").stdout.strip())

    def test_count_over_a_range(self):
        self.assertEqual("1", self.refs("count", "mid..main", "7").stdout.strip())

    def test_numbers_every_issue_named_ascending(self):
        self.assertEqual(["7", "8", "9", "11"], self.refs("numbers", "main").stdout.split())

    def test_commits_the_right_ones(self):
        self.assertEqual(2, len(self.refs("commits", "main", "7").stdout.splitlines()))

    def test_an_unknown_revision_names_nothing_and_exits_0(self):
        result = self.refs("count", "no-such-ref", "7")
        self.assertEqual((0, "0"), (result.returncode, result.stdout.strip()))

    def test_named_from_a_message_on_stdin(self):
        self.assertEqual(["3", "4"], run("board-refs.py", "named", stdin="x\n\nRefs #4\nCloses #3\nfixes #5\n").stdout.split())

    def test_branch(self):
        self.assertEqual("415", run("board-refs.py", "branch", "415-x").stdout.strip())

    def test_an_unnumbered_branch_prints_nothing(self):
        self.assertEqual("", run("board-refs.py", "branch", "tidy-up").stdout.strip())

    def test_an_unknown_command_is_refused(self):
        self.assertEqual(2, run("board-refs.py", "frobnicate").returncode)


if __name__ == "__main__":
    unittest.main()
