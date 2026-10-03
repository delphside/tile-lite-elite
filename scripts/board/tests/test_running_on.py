"""What an environment is running, named. #383 R3.

Preview ran PR #420's branch tip on 2026-09-26 and board-status.py said "up
to date with main": true, because it had everything on main, and misleading,
because it was not on main at all. A real history is built here rather than
canned, because the answer is git's.
"""

import os
import subprocess
import tempfile
import unittest

from board.programme import branch_line
from board.repo import behind_main, running_on

from .cases import Cases

PRS = {"415-x": (420, "#415 Admin CLI, tests, countdown")}


class RunningOn(Cases):
    @classmethod
    def setUpClass(cls):
        cls._dir = tempfile.TemporaryDirectory()
        cls._was = os.getcwd()
        os.chdir(cls._dir.name)

        def git(*args):
            return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()

        def commit(text):
            with open("f", "w") as f:
                f.write(text + "\n")
            git("add", "f")
            git("commit", "-q", "-m", text)
            return git("rev-parse", "--short", "HEAD")

        git("init", "-q", "-b", "main", ".")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "test")
        cls.A = commit("a")
        git("update-ref", "refs/remotes/origin/main", "HEAD")
        git("checkout", "-q", "-b", "415-x")
        cls.B = commit("b")
        cls.C = commit("c")
        git("update-ref", "refs/remotes/origin/415-x", "HEAD")
        git("checkout", "-q", "main")
        cls.D = commit("d")
        git("update-ref", "refs/remotes/origin/main", "HEAD")

    @classmethod
    def tearDownClass(cls):
        os.chdir(cls._was)
        cls._dir.cleanup()

    def test_on_main(self):
        where = running_on(f"0.8.2+{self.D}")
        self.expect("main's tip is on main", True, where.on_main)
        self.expect("and needs no second line", None, branch_line(where, PRS))
        self.expect("an older main commit is on main too", True, running_on(f"0.8.2+{self.A}").on_main)

    def test_on_a_branch(self):
        where = running_on(f"0.8.2+{self.C}")
        self.expect("a branch tip is not on main", False, where.on_main)
        self.expect("the branch is named", "415-x", where.branch)
        self.expect("as its latest commit", True, where.at_tip)
        self.expect("with its pull request",
                    "branch 415-x, its latest commit · PR #420 for #415 Admin CLI, tests, countdown",
                    branch_line(where, PRS))
        older = running_on(f"0.8.2+{self.B}")
        self.expect("an older commit on the branch says so", (False, "415-x", False),
                    (older.on_main, older.branch, older.at_tip))
        self.expect("a branch with no pull request is still named",
                    "branch 415-x, its latest commit", branch_line(where, {}))

    def test_behind_main_as_well(self):
        self.expect("the branch lacks main's newest commit, and that is still counted",
                    "1 change behind main", behind_main(f"0.8.2+{self.C}"))

    def test_nothing_to_go_on(self):
        self.expect("a version with no commit", None, running_on("0.8.2"))
        self.expect("a commit this clone does not have", None, running_on("0.8.2+deadbee"))


if __name__ == "__main__":
    unittest.main()
