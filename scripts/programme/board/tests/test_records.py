"""Where the programme's files are read from and written to (#485 T4).

From the design, not the code: generic documents come from the pinned
submodule, records from the live checkout (`PROGRAMME_DIR`, default
`<repo>/../programme`), and a script that needs the live checkout and does not
find it says where it looked and exits non-zero -- it never falls back to the
pinned copy, which would read an old record and write a new one nowhere.

Each case runs the command as a caller would, with a temporary directory as
`PROGRAMME_DIR`.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from board import records
from board.tests.cases import Cases
from board.tests.cli import run

REGISTER = """\
| id | activity | frequency (days) | owner | produces | ITIL practice |
| --- | --- | --- | --- | --- | --- |
| `capacity-plan` | Produce and review the capacity plan | 30 | Claude | a report | test only |
"""
MEASUREMENTS = ("period,metric,value,ceiling,unit\n"
                "2026-08,disk,5.0,45,GB\n2026-09,disk,6.1,45,GB\n2026-10,disk,7.0,45,GB\n")


def env(**extra):
    base = {k: v for k, v in os.environ.items() if k != "PROGRAMME_DIR"}
    return {**base, **extra}


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t",
                    *args], check=True, capture_output=True)


def make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "main")
    (path / "f").write_text("1")
    git(path, "add", "f")
    git(path, "commit", "-q", "-m", "one")
    return path


class TheDefaultFromAWorktree(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.top = Path(self._dir.name).resolve()
        self.addCleanup(self._restore, os.environ.pop("PROGRAMME_DIR", None))

    @staticmethod
    def _restore(old):
        if old is not None:
            os.environ["PROGRAMME_DIR"] = old

    def test_a_linked_worktree_finds_the_checkout_beside_the_main_worktree(self):
        main = make_repo(self.top / "repo")
        (self.top / "programme").mkdir()
        wt = main / ".claude" / "worktrees" / "agent-1"
        git(main, "worktree", "add", "-q", str(wt), "-b", "work")
        self.expect("same as from the main checkout", self.top / "programme", records.live(main))
        self.expect("and from the worktree under it", self.top / "programme", records.live(wt))

    def test_the_variable_still_overrides_in_a_worktree(self):
        main = make_repo(self.top / "repo")
        wt = main / ".claude" / "worktrees" / "agent-1"
        git(main, "worktree", "add", "-q", str(wt), "-b", "work")
        elsewhere = self.top / "elsewhere"
        elsewhere.mkdir()
        os.environ["PROGRAMME_DIR"] = str(elsewhere)
        self.expect("override wins", elsewhere, records.live(wt))


class TheStartOfSessionCheck(Cases):
    """One line naming the path and the problem; nothing when all is well."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.top = Path(self._dir.name).resolve()
        self.origin = make_repo(self.top / "origin")
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.top / "programme")],
                       check=True, capture_output=True)
        self.live = self.top / "programme"
        self.addCleanup(self._restore, os.environ.pop("PROGRAMME_DIR", None))
        os.environ["PROGRAMME_DIR"] = str(self.live)

    @staticmethod
    def _restore(old):
        os.environ.pop("PROGRAMME_DIR", None)
        if old is not None:
            os.environ["PROGRAMME_DIR"] = old

    def test_a_current_checkout_on_main_says_nothing(self):
        self.expect("no problem", None, records.problem())
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("prints nothing", "", result.stdout + result.stderr)

    def test_missing(self):
        gone = self.top / "not-cloned"
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(gone)))
        self.expect("never fails the session", 0, result.returncode)
        self.expect("one line", 1, len(result.stdout.strip().splitlines()))
        self.expect("names the path", True, str(gone) in result.stdout)
        self.expect("says missing", True, "missing" in result.stdout)

    def test_on_another_branch(self):
        git(self.live, "checkout", "-q", "-b", "side")
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("one line", 1, len(result.stdout.strip().splitlines()))
        self.expect("names the path", True, str(self.live) in result.stdout)
        self.expect("names the branch", True, "side" in result.stdout)

    def test_behind_origin_main(self):
        (self.origin / "g").write_text("2")
        git(self.origin, "add", "g")
        git(self.origin, "commit", "-q", "-m", "two")
        git(self.live, "fetch", "-q", "origin")
        before = subprocess.run(["git", "-C", str(self.live), "rev-parse", "HEAD"],
                                capture_output=True, text=True).stdout
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("one line", 1, len(result.stdout.strip().splitlines()))
        self.expect("names the path", True, str(self.live) in result.stdout)
        self.expect("says behind", True, "behind" in result.stdout)
        after = subprocess.run(["git", "-C", str(self.live), "rev-parse", "HEAD"],
                               capture_output=True, text=True).stdout
        self.expect("never changes the checkout", before, after)

    def test_no_origin_main_ref_cannot_tell(self):
        git(self.live, "update-ref", "-d", "refs/remotes/origin/main")
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("says cannot tell", True, "cannot tell" in result.stdout)
        self.expect("one line", 1, len(result.stdout.strip().splitlines()))


class TheLiveCheckout(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.live = Path(self._dir.name) / "programme"
        self.live.mkdir()
        self.missing = Path(self._dir.name) / "not-cloned"

    def test_the_helper_finds_it_by_the_variable(self):
        old = os.environ.get("PROGRAMME_DIR")
        os.environ["PROGRAMME_DIR"] = str(self.live)
        self.addCleanup(lambda: os.environ.pop("PROGRAMME_DIR") if old is None
                        else os.environ.__setitem__("PROGRAMME_DIR", old))
        self.expect("the live checkout is the variable's", self.live, records.live())
        self.expect("the log is a record, in it", self.live / "records" / "2.3-activity-log.csv",
                    records.activity_log())
        self.expect("this application's capacity plan",
                    self.live / "applications" / "tile-lite-elite" / "3.1.3-capacity-plan",
                    records.capacity_plan())
        self.expect("the register is generic, from the pinned submodule, not the live checkout",
                    records.ROOT / "programme" / "docs" / "1.4-programme-activities.md",
                    records.activity_register())

    def test_the_default_is_beside_the_repository(self):
        old = os.environ.pop("PROGRAMME_DIR", None)
        if old is not None:
            self.addCleanup(os.environ.__setitem__, "PROGRAMME_DIR", old)
        self.expect("one constant", "../programme", records.DEFAULT_PROGRAMME_DIR)
        beside = Path(self._dir.name) / "repo"
        (Path(self._dir.name) / "programme").mkdir(exist_ok=True)
        self.expect("<repo>/../programme", Path(self._dir.name) / "programme", records.live(beside))

    def test_missing_says_where_it_looked_and_exits_non_zero(self):
        result = run("programme/board/board-records.py", "live", env=env(PROGRAMME_DIR=str(self.missing)))
        self.expect("non-zero", True, result.returncode != 0)
        self.expect("names the path it tried", True, str(self.missing) in result.stderr)
        self.expect("prints nothing a caller could take for a path", "", result.stdout)

    def test_the_command_prints_the_path_for_shell_scripts(self):
        result = run("programme/board/board-records.py", "live", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("the path", str(self.live), result.stdout.strip())
        self.expect("generic is the submodule", str(records.ROOT / "programme"),
                    run("programme/board/board-records.py", "generic").stdout.strip())

    def test_the_activity_log_is_read_from_the_live_checkout(self):
        (self.live / "records").mkdir()
        (self.live / "records" / "2.3-activity-log.csv").write_text(
            "date,activity,who,note\n2000-01-01,capacity-plan,Claude,long ago\n")
        reg = Path(self._dir.name) / "register.md"
        reg.write_text(REGISTER)
        result = run("programme/board/board-practices.py", "--exit-code",
                     env=env(PROGRAMME_DIR=str(self.live), REGISTER_OVERRIDE=str(reg)))
        self.expect("the old row in the live log makes it overdue", 1, result.returncode)
        self.expect("and says so", True, "OVERDUE" in result.stdout)

    def test_practices_without_the_checkout_cannot_tell(self):
        reg = Path(self._dir.name) / "register.md"
        reg.write_text(REGISTER)
        result = run("programme/board/board-practices.py",
                     env=env(PROGRAMME_DIR=str(self.missing), REGISTER_OVERRIDE=str(reg)))
        self.expect("D46's 2: could not judge", 2, result.returncode)
        self.expect("names the path", True, str(self.missing) in result.stderr)

    def test_the_digest_without_the_checkout_stops_before_asking_github(self):
        result = run("programme/board/board-digest.py", "--write", env=env(PROGRAMME_DIR=str(self.missing)))
        self.expect("non-zero", True, result.returncode != 0)
        self.expect("names the path", True, str(self.missing) in result.stderr)

    def test_the_capacity_charts_are_written_to_the_live_checkout(self):
        plan = self.live / "applications" / "tile-lite-elite" / "3.1.3-capacity-plan"
        plan.mkdir(parents=True)
        (plan / "measurements.csv").write_text(MEASUREMENTS)
        result = run("programme/reports/capacity-chart.py", "--write", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("the chart is beside the data", True, (plan / "charts" / "disk.svg").is_file())

    def test_the_capacity_charts_without_the_checkout(self):
        result = run("programme/reports/capacity-chart.py", "--write", env=env(PROGRAMME_DIR=str(self.missing)))
        self.expect("non-zero", True, result.returncode != 0)
        self.expect("names the path", True, str(self.missing) in result.stderr)


if __name__ == "__main__":
    unittest.main()
