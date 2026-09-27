"""What reaches the image, decided once (#421).

The cases are docs/3.6's rule, not the pattern's: built into the image is a
Production Release, and everything else is not. `shipping-paths.bats` keeps
testing the functions the bash callers source, against real commits.
"""

import unittest

from board.shipping import image_paths, reaches_image, ships, touches_image, version_bump_only

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
        for path in ("docs/3.3-testing-ci-and-release.md", "scripts/deploy.sh", "e2e/tests/smoke.spec.ts",
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


class TheCommand(unittest.TestCase):
    def test_paths_prints_only_the_shipping_ones(self):
        self.assertEqual("Dockerfile", run("board-shipping.py", "paths", stdin="docs/a.md\nDockerfile\n").stdout.strip())

    def test_an_unknown_commit_changed_nothing(self):
        self.assertEqual(1, run("board-shipping.py", "commit", "no-such-commit").returncode)

    def test_an_unknown_command_is_refused(self):
        self.assertEqual(2, run("board-shipping.py", "frobnicate").returncode)


if __name__ == "__main__":
    unittest.main()
