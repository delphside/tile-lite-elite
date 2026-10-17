"""The gate counts what the board's model counts (#485).

`deploy.sh` refuses on `issue-mentions.sh`'s `commits_mentioning`, which is this
repository's; the pre-flight reports on the model's `mentions_on`, which is the
programme's (`programme/scripts/board/repo.py`). The failure nobody would see is
the pre-flight passing where the gate refuses, so the two are compared on one
history rather than read. The model's own cases (what counts as a trailer) are
in the programme's `board/tests/test_milestone.py`; this half moved here with
the gate it exercises.

The history is the one that test builds: on 2026-09-21 the model matched
case-insensitively and skipped merge commits, so two prose sentences counted as
trailers and #362's only trailer, on a merge into a release branch, counted for
nothing.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from board.repo import mentions_on

from board.tests.cases import Cases

GATE = Path(__file__).resolve().parents[1] / "deliver" / "issue-mentions.sh"


class TheGateCountsTheSame(Cases):
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

    def test_the_gate_counts_the_same(self):
        self.assertTrue(GATE.is_file(), f"{GATE} is not where this test looks")
        for n in (17, 99, 170, 362, 500, 501):
            gate = subprocess.run(["bash", "-c", f'source "{GATE}"; commits_mentioning HEAD {n}'],
                                  capture_output=True, text=True).stdout.strip()
            self.expect(f"#{n}", str(self.scope.count(n)), gate)


if __name__ == "__main__":
    unittest.main()
