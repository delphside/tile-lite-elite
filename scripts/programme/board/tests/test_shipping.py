"""What reaches the image, decided once (#421).

The cases are docs/5.1's rule, not the pattern's: built into the image is a
Production Release, and everything else is not. `shipping-paths.bats` keeps
testing the functions the bash callers source, against real commits.
"""

import unittest

from board.shipping import (application_tooling, image_paths, reaches_image, ships, touches_image,
                            version_bump_only)

from .cli import run

BUMP = ['-version = "0.9.0"', '+version = "0.9.1"']


class ReachesTheImage(unittest.TestCase):
    def test_built_in(self):
        for path in ("crates/server-game/src/app.rs", "crates/rules-shared/src/wordlists/greylist.txt",
                     "Cargo.toml", "Cargo.lock", "Dockerfile", "Caddyfile", "docker-compose.yml",
                     ".cargo/config.toml", "old-crates/first-try/src/main.rs"):
            with self.subTest(path):
                self.assertTrue(reaches_image(path))

    def test_not_built_in(self):
        for path in ("docs/3.3-testing-ci-and-release.md", "scripts/application/deliver/deploy.sh", "e2e/tests/smoke.spec.ts",
                     ".github/workflows/ci.yml", ".githooks/pre-commit", ".claude/settings.json",
                     ".cargo/audit.toml", "crates/server-game/examples/engine_timing_results.csv",
                     "crates/server-game/tests/api.rs", "crates/engine-core/benches/b.rs",
                     "crates/ui/README.md", "LICENSE", ".gitignore", ".markdownlint.json"):
            with self.subTest(path):
                self.assertFalse(reaches_image(path))


class AChange(unittest.TestCase):
    def test_one_shipping_path_among_many(self):
        self.assertEqual(["Cargo.lock"], image_paths(["docs/a.md", "Cargo.lock", "scripts/x.sh"]))

    def test_a_change_that_touched_nothing_reaches_nothing(self):
        self.assertFalse(touches_image([]))


class AVersionBump(unittest.TestCase):
    def test_cargo_toml_alone_version_lines_only(self):
        self.assertTrue(version_bump_only(["Cargo.toml"], BUMP))

    def test_with_cargo_lock_version_lines_only(self):
        self.assertTrue(version_bump_only(["Cargo.lock", "Cargo.toml"], BUMP * 8))

    def test_a_dependency_line_is_not_a_bump(self):
        self.assertFalse(version_bump_only(["Cargo.toml"], BUMP + ['+anyhow = "1"']))

    def test_another_file_alongside_is_not_a_bump(self):
        self.assertFalse(version_bump_only(["Cargo.toml", "crates/api/src/lib.rs"], BUMP))

    def test_no_changed_lines_is_not_a_bump(self):
        self.assertFalse(version_bump_only(["Cargo.toml"], []))

    def test_a_two_part_version_is_not_ours(self):
        self.assertFalse(version_bump_only(["Cargo.toml"], ['+version = "1.0"']))


class Ships(unittest.TestCase):
    def test_the_post_release_bump_ships_nothing(self):
        self.assertFalse(ships(["Cargo.lock", "Cargo.toml"], BUMP))

    def test_a_dockerfile_change_ships(self):
        self.assertTrue(ships(["Dockerfile"], []))

    def test_a_document_ships_nothing(self):
        self.assertFalse(ships(["docs/a.md"], []))

    def test_a_crate_change_ships(self):
        self.assertTrue(ships(["crates/ui/src/app.rs"], []))


class ApplicationTooling(unittest.TestCase):
    """The application's tooling is what scripts/application/ holds (docs/3.0, #421 R2).

    What the folder means is the rule: scripts that act on the application and its
    environments, which take a branch. The programme's scripts and the tests are not it.
    """

    def test_a_script_in_any_of_the_four_folders_is(self):
        for path in ("scripts/application/develop/services.sh", "scripts/application/deliver/deploy.sh",
                     "scripts/application/operate/backup-to-oci.sh", "scripts/application/measure/bench-compare.py",
                     "scripts/application/operate/systemd/tile-lite-elite-backup.timer"):
            with self.subTest(path):
                self.assertEqual([path], application_tooling([path]))

    def test_the_programmes_scripts_and_the_tests_are_not(self):
        for path in ("scripts/programme/board/model.py", "scripts/programme/docs/check-docs.sh",
                     "scripts/tests/deploy.bats", "docs/3.0-tools.md", ".github/workflows/ci.yml",
                     "crates/server-game/src/app.rs", "scripts/applications/x.sh", "scripts/application"):
            with self.subTest(path):
                self.assertEqual([], application_tooling([path]))

    def test_of_a_mixed_change_only_the_application_paths_come_back_in_order(self):
        self.assertEqual(["scripts/application/deliver/a.sh", "scripts/application/develop/b.sh"],
                         application_tooling(["docs/a.md", "scripts/application/deliver/a.sh", "",
                                              "scripts/programme/board/x.py", "scripts/application/develop/b.sh"]))


class TheCommand(unittest.TestCase):
    def test_application_tooling_prints_only_those_paths(self):
        out = run("programme/board/board-shipping.py", "application-tooling",
                  stdin="docs/a.md\nscripts/application/deliver/deploy.sh\nscripts/programme/board/model.py\n")
        self.assertEqual("scripts/application/deliver/deploy.sh", out.stdout.strip())
        self.assertEqual(0, out.returncode)

    def test_paths_prints_only_the_shipping_ones(self):
        self.assertEqual("Dockerfile", run("programme/board/board-shipping.py", "paths", stdin="docs/a.md\nDockerfile\n").stdout.strip())

    def test_an_unknown_commit_changed_nothing(self):
        self.assertEqual(1, run("programme/board/board-shipping.py", "commit", "no-such-commit").returncode)

    def test_an_unknown_command_is_refused(self):
        self.assertEqual(2, run("programme/board/board-shipping.py", "frobnicate").returncode)


if __name__ == "__main__":
    unittest.main()
