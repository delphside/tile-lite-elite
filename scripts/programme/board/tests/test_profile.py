"""The profile loader, #485 stage 2: the tooling holds no application's facts.

From the design, not the code: the programme file comes from the pinned
submodule, the programme profile from the live checkout and the technical
profile from the application's root; each can be replaced by a variable; and a
missing file or key stops the command, naming it. There is no fallback to a
built-in value, so each failure case below also checks that nothing was printed
that a caller could take for an answer.

Every case reads the fakes (`board.tests.profiles`) or a temporary application.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from board import profile
from board.tests import profiles
from board.tests.cases import Cases
from board.tests.cli import run


def get(key, **env):
    """`board-profile.py get <key>` as a caller would, with these variables set
    (None removes one) on top of the fakes."""
    return command("get", key, **env)


def command(*args, cwd=None, **env):
    merged = dict(os.environ)
    for name, value in env.items():
        if value is None:
            merged.pop(name, None)
        else:
            merged[name] = str(value)
    return run("programme/board/board-profile.py", *args, env=merged, cwd=cwd)


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "protocol.file.allow=always", *args], check=True, capture_output=True)


class TheMissingFile(Cases):
    """Each file the loader reads, absent: a clear message, a non-zero exit, no answer."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.tmp = Path(self._dir.name)
        self.nowhere = self.tmp / "nowhere.toml"

    def refused(self, result, *mentions):
        self.expect("exits non-zero", True, result.returncode != 0)
        self.expect("prints no answer", "", result.stdout)
        for text in mentions:
            self.expect(f"says {text!r}", True, text in result.stderr)

    def test_the_technical_profile_missing(self):
        self.refused(get("versions.stamp", PROGRAMME_PROFILE=self.nowhere),
                     str(self.nowhere), "technical profile")

    def test_the_programme_file_missing(self):
        self.refused(get("accounts.owner", PROGRAMME_CONFIG=self.nowhere),
                     str(self.nowhere), "programme file")

    def test_the_programme_profile_missing(self):
        empty = self.tmp / "live"
        empty.mkdir()
        self.refused(get("profile.identity.repository", PROGRAMME_DIR=empty),
                     "programme profile", str(empty / "applications" / "widget"))

    def test_the_live_checkout_missing(self):
        self.refused(get("profile.identity.repository", PROGRAMME_DIR=self.tmp / "not-cloned"),
                     str(self.tmp / "not-cloned"))

    def test_with_no_variables_the_files_are_looked_for_at_the_application(self):
        # A bare repository: nothing to read, so nothing is answered, and the
        # message names where each was looked for. No built-in value fills in.
        bare = self.tmp / "bare"
        bare.mkdir()
        git(bare, "init", "-q")
        technical = command("get", "versions.stamp", cwd=bare, PROGRAMME_PROFILE=None)
        self.refused(technical, str(bare / "programme.toml"))
        config = command("get", "accounts.owner", cwd=bare, PROGRAMME_CONFIG=None)
        self.refused(config, str(bare / "programme" / "config" / "programme.toml"), "submodule")

    def test_outside_a_repository_there_is_no_application(self):
        outside = self.tmp / "outside"
        outside.mkdir()
        self.refused(command("get", "versions.stamp", cwd=outside, PROGRAMME_PROFILE=None),
                     "not inside a git working tree")


class TheMissingKey(Cases):
    """A file that is there but does not hold what was asked for."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.tmp = Path(self._dir.name)

    def write(self, name, text):
        path = self.tmp / name
        path.write_text(text)
        return path

    def refused(self, result, *mentions):
        self.expect("exits non-zero", True, result.returncode != 0)
        self.expect("prints no answer", "", result.stdout)
        for text in mentions:
            self.expect(f"says {text!r}", True, text in result.stderr)

    def test_a_technical_key_missing_names_the_file_and_the_key(self):
        path = self.write("t.toml", '[versions]\nstamp_form = "x"\n')
        self.refused(get("versions.stamp", PROGRAMME_PROFILE=path), str(path), "versions.stamp")

    def test_a_section_missing_names_how_far_it_got(self):
        path = self.write("t.toml", 'application = "widget"\n')
        self.refused(get("release.tag_prefix", PROGRAMME_PROFILE=path), str(path), "release")

    def test_a_programme_file_key_missing_names_the_file_and_the_key(self):
        path = self.write("c.toml", '[accounts]\nowner = "x"\n')
        self.refused(get("accounts.machine_user", PROGRAMME_CONFIG=path), str(path),
                     "accounts.machine_user")

    def test_a_profile_key_missing(self):
        self.refused(get("profile.identity.nonesuch"), "profile.identity.nonesuch")

    def test_a_profile_table_missing(self):
        live = self.tmp / "live"
        folder = live / "applications" / "widget"
        folder.mkdir(parents=True)
        (folder / "3.6.6-profile.md").write_text("# a profile with no tables\n")
        self.refused(get("profile.identity.repository", PROGRAMME_DIR=live), "## Identity")

    def test_a_profile_row_missing(self):
        live = self.tmp / "live"
        folder = live / "applications" / "widget"
        folder.mkdir(parents=True)
        text = (profiles.LIVE / "applications" / "widget" / "3.6.6-profile.md").read_text()
        (folder / "3.6.6-profile.md").write_text(text.replace("| repository | `fakeorg/widget` |\n", ""))
        self.refused(get("profile.identity.name", PROGRAMME_DIR=live), "repository")

    def test_the_wrong_kind_of_value_is_refused(self):
        path = self.write("t.toml", 'application = "widget"\n[ships]\nnon_shipping = "docs/"\n')
        result = run("programme/board/board-shipping.py", "paths", stdin="docs/a.md\n",
                     env={**os.environ, "PROGRAMME_PROFILE": str(path)})
        self.expect("exits non-zero", True, result.returncode != 0)
        self.expect("names the key", True, "ships.non_shipping" in result.stderr)


class TheValues(Cases):
    def test_a_string(self):
        self.expect("value", "fakeorg\n", get("organisation.login").stdout)

    def test_a_list_is_one_item_per_line(self):
        self.expect("lines", "docs/9.1.4-\n", get("documents.programme_prefixes").stdout)

    def test_a_list_of_tables_is_one_named_block_per_table(self):
        out = get("hooks.check_docs").stdout
        self.expect("blocks of name=value lines, each ended by an empty line",
                    "name=first fake check\ncommand=scripts/fake-check-one.sh\n\n"
                    "name=second fake check\ncommand=scripts/fake-check-two.sh\n\n", out)

    def test_an_empty_value_is_still_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.toml"
            path.write_text('application = "widget"\n[[hooks.pre_commit]]\nfix = ""\nname = "n"\ncommand = "c"\n')
            out = get("hooks.pre_commit", PROGRAMME_PROFILE=path).stdout
        self.expect("every key keeps its name, whatever its value or its place in the file",
                    "fix=\nname=n\ncommand=c\n\n", out)

    def test_the_programme_documents_combine_both_files(self):
        exact, prefixes = profile.programme_documents()
        self.expect("the programme file's entries and the technical profile's own",
                    True, "CLAUDE.md" in exact and "docs/diagrams/roadmap.svg" in exact)
        self.expect("and the submodule as a prefix and an exact path", True,
                    "programme" in exact and "programme/" in prefixes and "docs/9.1.4-" in prefixes)

    def test_the_registers_combine_both_files(self):
        out = run("programme/board/board-profile.py", "registers").stdout.split()
        self.expect("the application's, then the programme's under the submodule",
                    ["docs/9.3.0-tools.md", "programme/docs/1.1-programme-tooling.md"], out)

    def test_a_misspelt_hook_key_is_refused_naming_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.toml"
            path.write_text('application = "widget"\n[[hooks.check_docs]]\nname = "n"\ncomand = "c"\n')
            result = get("hooks.check_docs", PROGRAMME_PROFILE=path)
        self.expect("exit 70", 70, result.returncode)
        self.expect("names the key", True, "`comand`" in result.stderr)

    def test_a_table_is_not_a_value(self):
        result = get("versions.app")
        self.expect("refused", True, result.returncode != 0)
        self.expect("says why", True, "table" in result.stderr)

    def test_the_programme_profile_is_asked_with_the_profile_prefix(self):
        self.expect("repository", "fakeorg/widget\n", get("profile.identity.repository").stdout)
        self.expect("a record's path by its suffix", "3.6.3-capacity-plan/\n", get("profile.records.3").stdout)

    def test_the_two_files_do_not_share_a_section(self):
        import tomllib
        technical = set(tomllib.loads(profiles.TECHNICAL.read_text()))
        self.expect("no overlap, or a key could answer from either", set(),
                    technical & set(profile.PROGRAMME_SECTIONS + (profile.PROFILE_PREFIX,)))
        shared = set(tomllib.loads(profiles.CONFIG.read_text()))
        self.expect("the programme file holds exactly the sections the loader routes to it",
                    set(profile.PROGRAMME_SECTIONS), shared)


class TheProgrammeProfile(Cases):
    def test_it_parses_the_fixed_tables(self):
        got = profile.application_profile()
        self.expect("identity", {"name": "Widget", "code": "WID", "number": "6",
                                 "repository": "fakeorg/widget", "board_view": "Widget",
                                 "document_range": "9"}, got["identity"])
        self.expect("versioning", "semver", got["versioning"]["scheme"])
        self.expect("environments, in the order written",
                    ["preview", "rehearsal", "production"], [e["name"] for e in got["environments"]])
        self.expect("a fixed URL", "https://widget.example", got["environments"][2]["url"])
        self.expect("an unfixed one is empty", ["", ""], [e["url"] for e in got["environments"][:2]])
        self.expect("routes", ["Production Release", "Other"], list(got["routes"]))
        self.expect("target architecture", "https://example.invalid/widget/docs/9.1.1-architecture.md",
                    got["target_architecture"])
        self.expect("records by their suffix", ["1", "2", "3", "4", "5", "6", "7"], list(got["records"]))

    def test_the_repository_is_split_into_owner_and_name(self):
        self.expect("owner and name", ("fakeorg", "widget"), profile.repository())

    def test_the_organisation_is_the_programme_files_not_the_repository_owner(self):
        self.expect("organisation", "fakeorg", profile.organisation())


class TheApplicationsRoot(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.tmp = Path(self._dir.name).resolve()

    def test_a_working_tree_is_its_own_root(self):
        app = self.tmp / "app"
        app.mkdir()
        git(app, "init", "-q")
        (app / "sub").mkdir()
        self.expect("from the top", app, profile.app_root(app))
        self.expect("from a folder in it", app, profile.app_root(app / "sub"))

    def test_inside_a_submodule_it_is_the_superproject(self):
        library = self.tmp / "library"
        library.mkdir()
        git(library, "init", "-q", "-b", "main")
        (library / "f").write_text("1")
        git(library, "add", "f")
        git(library, "commit", "-q", "-m", "one")
        app = self.tmp / "app"
        app.mkdir()
        git(app, "init", "-q", "-b", "main")
        git(app, "submodule", "add", "-q", str(library), "programme")
        self.expect("from inside the submodule", app, profile.app_root(app / "programme"))
        self.expect("from the application", app, profile.app_root(app))

    def test_a_linked_worktree_is_its_own_root(self):
        app = self.tmp / "app"
        app.mkdir()
        git(app, "init", "-q", "-b", "main")
        (app / "f").write_text("1")
        git(app, "add", "f")
        git(app, "commit", "-q", "-m", "one")
        linked = app / ".claude" / "worktrees" / "w"
        git(app, "worktree", "add", "-q", str(linked), "-b", "work")
        self.expect("the profile travels with the branch", linked, profile.app_root(linked))

    def test_the_programme_file_is_read_from_the_pinned_submodule(self):
        app = self.tmp / "app"
        (app / "programme" / "config").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(app)], check=True)
        shutil.copy(profiles.CONFIG, app / "programme" / "config" / "programme.toml")
        env = {k: v for k, v in os.environ.items() if k != "PROGRAMME_CONFIG"}
        result = run("programme/board/board-profile.py", "get", "accounts.owner", cwd=app, env=env)
        self.expect("exit", 0, result.returncode)
        self.expect("read from the pin", "fake-owner\n", result.stdout)


class TheVersions(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.app = Path(self._dir.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.app)], check=True)
        (self.app / "crates" / "api" / "src").mkdir(parents=True)
        (self.app / "scripts").mkdir()
        shutil.copy(Path(__file__).resolve().parents[3] / "read-api-version.sh",
                    self.app / "scripts" / "read-api-version.sh")

    def test_the_app_version_is_the_first_match_in_the_profiles_file(self):
        (self.app / "Cargo.toml").write_text('[package]\nname = "x"\nversion = "1.2.3"\n[dep]\nversion = "9"\n')
        self.expect("app", "1.2.3", profile.current_version("app", self.app))
        self.expect("through the command", "1.2.3\n", command("version", "app", cwd=self.app).stdout)

    def test_the_api_version_is_what_the_profiles_command_prints(self):
        (self.app / "crates" / "api" / "src" / "lib.rs").write_text(
            "pub const API_VERSION: ApiVersion = ApiVersion { major: 2, minor: 10 };\n")
        self.expect("api", "2.10", profile.current_version("api", self.app))

    def test_a_tree_without_the_file_has_no_version_and_that_is_not_an_error(self):
        self.expect("none", None, profile.current_version("app", self.app))
        result = command("version", "app", cwd=self.app)
        self.expect("exit", 0, result.returncode)
        self.expect("nothing printed", "", result.stdout)

    def test_a_different_profile_reads_a_different_file(self):
        (self.app / "VERSION").write_text("app=77\n")
        (self.app / "Cargo.toml").write_text('version = "1.2.3"\n')
        other = command("version", "app", cwd=self.app, PROGRAMME_PROFILE=profiles.OTHER_TECHNICAL)
        self.expect("the other profile's file and pattern", "77\n", other.stdout)


if __name__ == "__main__":
    unittest.main()
