"""Each fact the tooling used to hold is read from a profile now (#485 stage 2).

A test here changes the profile and shows the answer change with it, which a
test against one fixed profile cannot: the fake application's values equal the
old built-in ones in places, so passing against it proves little. Each case
reads `fixtures/programme.toml` and then `fixtures/programme-other.toml` (a
different stamp, tag prefix, version files and ships list) or a profile with
the key removed, which must fail naming the key.
"""

import http.server
import json
import os
import subprocess
import tempfile
import textwrap
import threading
import unittest
from datetime import date
from pathlib import Path

from board import digest, documents, profile, programme, repo, shipping, sources
from board.tests.cases import Cases
from board.tests.profiles import OTHER_TECHNICAL, inside, using


def repository(top: Path) -> Path:
    top.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", "-b", "main", str(top)], check=True)
    subprocess.run(["git", "-C", str(top), "-c", "user.name=t", "-c", "user.email=t@t",
                    "commit", "-q", "--allow-empty", "-m", "one"], check=True)
    return top


def raises_naming(testcase, key, call):
    with testcase.assertRaises(profile.ProfileError) as caught:
        call()
    testcase.assertIn(key, caught.exception.message)


class WhatShips(Cases):
    def test_the_list_is_the_profiles(self):
        self.expect("the fake's own entry does not ship", False, shipping.reaches_image("notes/a.rs"))
        with using(OTHER_TECHNICAL):
            self.expect("under the other profile it does", True, shipping.reaches_image("notes/a.rs"))
            self.expect("and its own entries do not", False, shipping.reaches_image("spec/a.rs"))
            self.expect("a text file anywhere does not", False, shipping.reaches_image("x/y.txt"))
            self.expect("the first profile's docs/ is no longer excluded", True, shipping.reaches_image("docs/a.rs"))

    def test_a_version_bump_is_the_profiles_files_and_line(self):
        self.expect("by the first profile", True,
                    shipping.version_bump_only(["Cargo.toml"], ['-version = "0.9.0"', '+version = "0.9.1"']))
        with using(OTHER_TECHNICAL):
            self.expect("not by the other", False,
                        shipping.version_bump_only(["Cargo.toml"], ['-version = "0.9.0"', '+version = "0.9.1"']))
            self.expect("its own file and line", True, shipping.version_bump_only(["VERSION"], ["-app=1", "+app=2"]))
            self.expect("with its lock file", True,
                        shipping.version_bump_only(["VERSION", "VERSION.lock"], ["-app=1", "+app=2"]))
            self.expect("but nothing else beside", False,
                        shipping.version_bump_only(["VERSION", "src/a.rs"], ["-app=1", "+app=2"]))

    def test_a_profile_without_the_list_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            bare = Path(tmp) / "programme.toml"
            bare.write_text('application = "widget"\n')
            with using(bare):
                raises_naming(self, "ships.non_shipping", lambda: shipping.reaches_image("a"))


class WhichDocuments(Cases):
    def test_the_lists_are_the_profiles(self):
        self.expect("a programme document by the first", "programme", documents.kind("docs/9.1.4-roadmap.md"))
        with using(OTHER_TECHNICAL):
            raises_naming(self, "documents.generated", lambda: documents.kind("docs/9.1.4-roadmap.md"))


class WhoSaidIt(Cases):
    def test_the_comment_filter_names_the_profiles_announcement_and_account(self):
        jq = sources.comment_jq("issue_url")
        self.expect("announcement", True, 'startswith("Shipped in rel-")' in jq)
        self.expect("machine user", True, '"fake-owner-claude"' in jq)
        with using(OTHER_TECHNICAL):
            self.expect("another announcement", True, 'startswith("Out as v-")' in sources.comment_jq("issue_url"))

    def test_the_repository_and_board_are_the_profiles(self):
        self.expect("the repository", ("fakeorg", "widget"), sources._repository())
        self.expect("the board", "PVT_fakeboard", sources._project_id())


class TheDigest(Cases):
    def test_the_stamp_is_the_profiles(self):
        self.expect("the first", "the change", digest._subject_without_stamp("app 1.2.3 api 4.5: the change"))
        self.expect("not matching is kept whole", "v7 / 8: the change",
                    digest._subject_without_stamp("v7 / 8: the change"))
        with using(OTHER_TECHNICAL):
            self.expect("the other", "the change", digest._subject_without_stamp("v7 / 8: the change"))

    def test_a_weekly_digest_is_named_by_the_programme_files_code(self):
        self.expect("code, year and ISO week", "FAKE_WD_2026_W42", digest.report_code(date(2026, 10, 16)))
        self.expect("the week number is padded", "FAKE_WD_2026_W02", digest.report_code(date(2026, 1, 8)))


class TheTags(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.top = repository(Path(self._dir.name) / "app")
        for tag in ("rel-0.8.0", "v-0.9.0", "prod-0.1.0"):
            subprocess.run(["git", "-C", str(self.top), "tag", tag], check=True)

    def test_milestones_shipped_are_those_with_the_profiles_tag_prefix(self):
        with inside(self.top):
            self.expect("first profile", frozenset({"0.8.0"}), repo.Commits().shipped_milestones())
            with using(OTHER_TECHNICAL):
                self.expect("other profile", frozenset({"0.9.0"}), repo.Commits().shipped_milestones())

    def test_the_last_tag_is_the_profiles(self):
        with inside(self.top):
            self.expect("first", "rel-0.8.0", repo.commits().last_tag)
            with using(OTHER_TECHNICAL):
                self.expect("other", "v-0.9.0", repo.commits().last_tag)

    def test_the_version_lines_are_those_of_the_profiles_files(self):
        (self.top / "Cargo.toml").write_text('version = "0.1.0"\n')
        (self.top / "VERSION").write_text("app=1\n")
        subprocess.run(["git", "-C", str(self.top), "add", "-A"], check=True)
        with inside(self.top):
            self.expect("first", ['+version = "0.1.0"'], repo.staged()[1])
            with using(OTHER_TECHNICAL):
                self.expect("other", ["+app=1"], repo.staged()[1])


class TheEnvironments(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.app = repository(Path(self._dir.name) / "app")
        (self.app / "scripts").mkdir()
        (self.app / "scripts" / "rehearsal-target.sh").write_text("export TARGET_URL=https://rehearsal.example\n")
        self.addCleanup(self._restore, {k: os.environ.pop(k, None) for k in
                                        ("WIDGET_PREVIEW_URL", "WIDGET_REHEARSAL_URL", "WIDGET_PROD_URL")})

    @staticmethod
    def _restore(saved):
        for key, value in saved.items():
            if value is not None:
                os.environ[key] = value

    def url(self, name, fixed=""):
        return programme._environment_url(name, fixed, self.app)

    def test_a_fixed_url_is_the_programme_profiles(self):
        self.expect("production", "https://widget.example", self.url("production", "https://widget.example"))

    def test_a_default_is_the_technical_profiles(self):
        self.expect("preview", "http://localhost:9001", self.url("preview"))

    def test_a_script_is_the_technical_profiles_and_is_read_in_a_subshell(self):
        self.expect("rehearsal", "https://rehearsal.example", self.url("rehearsal"))

    def test_a_variable_the_profile_names_overrides_all(self):
        os.environ["WIDGET_PREVIEW_URL"] = "http://elsewhere"
        self.expect("preview", "http://elsewhere", self.url("preview"))
        os.environ["WIDGET_PROD_URL"] = "https://moved.example"
        self.expect("a fixed url too", "https://moved.example", self.url("production", "https://widget.example"))

    def test_the_old_names_are_not_read(self):
        os.environ["PROD_URL"] = "https://not-ours.example"
        self.addCleanup(os.environ.pop, "PROD_URL")
        self.expect("production", "https://widget.example", self.url("production", "https://widget.example"))

    def test_an_environment_with_no_way_to_find_it_is_refused(self):
        raises_naming(self, "environments.nonesuch", lambda: self.url("nonesuch"))

    def test_the_report_lists_the_programme_profiles_environments_in_its_order(self):
        names = [row["name"] for row in profile.application_profile(self.app)["environments"]]
        self.expect("order", ["preview", "rehearsal", "production"], names)

    def test_an_environments_version_is_read_where_the_profile_says(self):
        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"app_version": "9.9.9+abc1234", "v": "other"}).encode() \
                    if self.path == "/health" else b"{}"
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Health)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}"
        self.expect("the first profile's path and field", "9.9.9+abc1234", repo.live_version(url))
        with using(OTHER_TECHNICAL):
            self.expect("the other's path has nothing", None, repo.live_version(url))


class TheCiGate(Cases):
    def test_the_command_is_the_profiles_and_its_complaint_is_returned(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = repository(Path(tmp) / "app")
            (app / "scripts").mkdir()
            script = app / "scripts" / "ci-status.sh"
            script.write_text(textwrap.dedent("""\
                #!/bin/sh
                echo "args: $*"
                echo "the run concluded failure"
                exit 1
                """))
            script.chmod(0o755)
            with inside(app):
                self.expect("the run named in the profile is asked for",
                            "the run concluded failure", repo.ci_red_on_main())

    def test_an_absent_command_says_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            with inside(repository(Path(tmp) / "app")):
                self.expect("not red", None, repo.ci_red_on_main())


class TheReviewStamp(Cases):
    def test_a_document_is_stamped_by_the_profiles_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = repository(Path(tmp) / "app")
            (app / "docs").mkdir()
            (app / "docs" / "a.md").write_text("Checked whole at `abc1234`\n")
            (app / "docs" / "b.md").write_text("Reviewed whole at `abc1234`\n")
            with inside(app):
                _flagged, unstamped = programme.documents_to_reread()
        self.expect("only the one without the profile's line", ["b.md"], unstamped)


class TheVersionsRead(Cases):
    def test_the_milestone_being_built_is_the_profiles_version_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = repository(Path(tmp) / "app")
            (app / "Cargo.toml").write_text('version = "1.0.0"\n')
            (app / "VERSION").write_text("app=2\n")
            self.expect("first", "1.0.0", profile.current_version("app", app))
            with using(OTHER_TECHNICAL):
                self.expect("other", "2", profile.current_version("app", app))


if __name__ == "__main__":
    unittest.main()
