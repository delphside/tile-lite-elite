"""Where the programme's files are read from and written to (#485 T4).

From the design, not the code: generic documents come from the pinned
submodule, records from the live checkout (`PROGRAMME_DIR`, default the programme
file's `programme.live_default` beside the main worktree), and a script that needs the live checkout and does not
find it says where it looked and exits non-zero -- it never falls back to the
pinned copy, which would read an old record and write a new one nowhere.

Each case runs the command as a caller would, with a temporary directory as
`PROGRAMME_DIR`. The profiles are the fakes (`board.tests.profiles`).
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from board import profile, records
from board.tests.cases import Cases
from board.tests.cli import run
from board.tests.profiles import APPLICATION, install_profile

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
        (self.top / "fake-programme").mkdir()
        wt = main / ".claude" / "worktrees" / "agent-1"
        git(main, "worktree", "add", "-q", str(wt), "-b", "work")
        self.expect("same as from the main checkout", self.top / "fake-programme", records.live(main))
        self.expect("and from the worktree under it", self.top / "fake-programme", records.live(wt))

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
        install_profile(self.origin)
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "-q", "-m", "profile")
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

    def test_a_missing_programme_file_is_said_in_one_line_and_does_not_fail(self):
        gone = self.top / "no-such.toml"
        result = run("programme/board/board-records.py", "check",
                     env=env(PROGRAMME_DIR=str(self.live), PROGRAMME_CONFIG=str(gone)))
        self.expect("never fails the session", 0, result.returncode)
        self.expect("one line", 1, len(result.stdout.strip().splitlines()))
        self.expect("names the file", True, str(gone) in result.stdout)

    def test_a_branch_at_origin_main_says_nothing(self):
        # Cloud sessions put every repository on a session branch.
        git(self.live, "checkout", "-q", "-b", "claude/session")
        self.expect("no problem", None, records.problem())
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("prints nothing", "", result.stdout + result.stderr)

    def test_a_branch_behind_origin_main_says_behind(self):
        git(self.live, "checkout", "-q", "-b", "claude/session")
        (self.origin / "g").write_text("2")
        git(self.origin, "add", "g")
        git(self.origin, "commit", "-q", "-m", "two")
        git(self.live, "fetch", "-q", "origin")
        result = run("programme/board/board-records.py", "check", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("one line", 1, len(result.stdout.strip().splitlines()))
        self.expect("says 1 behind", True, "1 commit(s) behind" in result.stdout)

    def test_a_detached_head_is_judged_the_same_way(self):
        git(self.live, "checkout", "-q", "--detach")
        self.expect("no problem", None, records.problem())

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
        self.live = Path(self._dir.name) / "fake-programme"
        self.live.mkdir()
        install_profile(self.live)
        self.missing = Path(self._dir.name) / "not-cloned"

    def test_the_helper_finds_it_by_the_variable(self):
        old = os.environ.get("PROGRAMME_DIR")
        os.environ["PROGRAMME_DIR"] = str(self.live)
        self.addCleanup(lambda: os.environ.pop("PROGRAMME_DIR") if old is None
                        else os.environ.__setitem__("PROGRAMME_DIR", old))
        self.expect("the live checkout is the variable's", self.live, records.live())
        self.expect("the log is a record, in it", self.live / "records" / "2.3-activity-log.csv",
                    records.activity_log())
        self.expect("this application's capacity plan, by the path its programme profile gives",
                    self.live / "applications" / APPLICATION / "3.6.3-capacity-plan",
                    records.capacity_plan())
        self.expect("and its change documents",
                    self.live / "applications" / APPLICATION / "3.6.7-changes",
                    records.change_documents())
        self.expect("the register is generic, from the pinned submodule, not the live checkout",
                    profile.app_root() / "programme" / "docs" / "1.4-programme-activities.md",
                    records.activity_register())

    def test_the_default_is_beside_the_repository(self):
        old = os.environ.pop("PROGRAMME_DIR", None)
        if old is not None:
            self.addCleanup(os.environ.__setitem__, "PROGRAMME_DIR", old)
        beside = make_repo(Path(self._dir.name) / "repo")
        (Path(self._dir.name) / "fake-programme").mkdir(exist_ok=True)
        self.expect("the programme file's default, beside the repository",
                    Path(self._dir.name) / "fake-programme", records.live(beside))

    def test_missing_says_where_it_looked_and_exits_non_zero(self):
        result = run("programme/board/board-records.py", "live", env=env(PROGRAMME_DIR=str(self.missing)))
        self.expect("non-zero", True, result.returncode != 0)
        self.expect("names the path it tried", True, str(self.missing) in result.stderr)
        self.expect("prints nothing a caller could take for a path", "", result.stdout)

    def test_missing_names_the_programme_repository_the_programme_file_names(self):
        result = run("programme/board/board-records.py", "live", env=env(PROGRAMME_DIR=str(self.missing)))
        self.expect("clone it from there", True, "clone fakeorg/fake-programme there" in result.stderr)

    def test_the_change_documents_are_asked_by_a_command_for_shell_scripts(self):
        result = run("programme/board/board-records.py", "change-documents", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("the path its programme profile gives", str(self.live / "applications" / APPLICATION / "3.6.7-changes"),
                    result.stdout.strip())

    def test_without_the_applications_profile_there_are_no_records_to_name(self):
        bare = Path(self._dir.name) / "bare-live"
        bare.mkdir()
        result = run("programme/board/board-records.py", "change-documents", env=env(PROGRAMME_DIR=str(bare)))
        self.expect("non-zero", True, result.returncode != 0)
        self.expect("says what is missing", True, "programme profile" in result.stderr)
        self.expect("prints nothing a caller could take for a path", "", result.stdout)

    def test_the_command_prints_the_path_for_shell_scripts(self):
        result = run("programme/board/board-records.py", "live", env=env(PROGRAMME_DIR=str(self.live)))
        self.expect("exit", 0, result.returncode)
        self.expect("the path", str(self.live), result.stdout.strip())
        self.expect("generic is the submodule", str(profile.app_root() / "programme"),
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
        plan = self.live / "applications" / APPLICATION / "3.6.3-capacity-plan"
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
