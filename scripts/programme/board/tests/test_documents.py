"""Which documents are the programme's and which the application's (#421 R5).

From the rules, owner 2026-09-25 and 2026-09-29/30: the programme's documents
describe the programme and change on main; the application's change with the
code; docs/4.1.5 and docs/4.1.6 are generated and belong to neither; everything in the
programme repository (change notes, templates, reports) is the programme's; and a path that is not a document
is neither.
"""

import unittest

from .cli import run


def of(which: str, *paths: str) -> list[str]:
    return run("programme/board/board-documents.py", which, stdin="".join(p + "\n" for p in paths)).stdout.split()


class ProgrammeDocuments(unittest.TestCase):
    def test_the_instructions_and_the_index(self):
        paths = ("CLAUDE.md", "AGENTS.md", "docs/README.md")
        self.assertEqual(list(paths), of("programme", *paths))

    def test_the_roadmap_and_its_diagram(self):
        paths = ("docs/4.1.4-roadmap.md", "docs/diagrams/roadmap.svg")
        self.assertEqual(list(paths), of("programme", *paths))

    def test_anything_in_the_programme_repository_and_its_pin(self):
        # #485: the generic documents and the records are in the programme
        # repository, here as the pinned submodule; its pin changes on main.
        paths = ("programme", "programme/docs/1.2-change-lifecycle.md",
                 "programme/applications/tile-lite-elite/3.1.1-delivery-log.md")
        self.assertEqual(list(paths), of("programme", *paths))

    def test_what_moved_out_is_not_a_programme_document_here(self):
        # The old paths no longer exist in this repository; if one turns up it is
        # an application document, not a programme one to be kept on main.
        paths = ("docs/5.1-change-lifecycle.md", "docs/templates/agent-handover.md",
                 "docs/changes/workstreams/a/71-x/71-design.md", "docs/programme-activity-log.csv",
                 "docs/diagrams/README.md")
        self.assertEqual([], of("programme", *paths))

    def test_an_application_document_is_not_one(self):
        self.assertEqual([], of("programme", "docs/4.4.3-api-schema.md", "docs/4.3.0-tools.md",
                                "scripts/programme/board/documents.py"))


class ApplicationDocuments(unittest.TestCase):
    def test_the_1x_overviews_of_the_application_and_the_2x_3x_4x_groups(self):
        paths = ("docs/4.1.0-rules.md", "docs/4.1.1-architecture.md", "docs/4.2.7-authentication-and-invitations.md",
                 "docs/4.3.3-testing-ci-and-release.md", "docs/4.3.10-benchmarking.md", "docs/4.4.2-database-schema.md")
        self.assertEqual(list(paths), of("application", *paths))

    def test_the_repository_readme(self):
        self.assertEqual(["README.md"], of("application", "README.md"))


class NeitherSide(unittest.TestCase):
    def test_the_generated_documents(self):
        paths = ("docs/4.1.5-work-in-progress.md", "docs/4.1.6-document-map.md")
        self.assertEqual([], of("programme", *paths))
        self.assertEqual([], of("application", *paths))

    def test_a_path_that_is_not_a_document(self):
        paths = ("scripts/deploy.sh", "crates/api/src/lib.rs", "e2e/README.md")
        self.assertEqual([], of("programme", *paths))
        self.assertEqual([], of("application", *paths))

    def test_kind_names_each(self):
        out = run("programme/board/board-documents.py", "kind", "CLAUDE.md", "docs/4.4.1-configuration.md",
                  "docs/4.1.6-document-map.md", "scripts/x.sh").stdout.split("\n")
        self.assertEqual(["CLAUDE.md\tprogramme", "docs/4.4.1-configuration.md\tapplication",
                          "docs/4.1.6-document-map.md\tgenerated", "scripts/x.sh\tnone"], out[:4])

    def test_an_unknown_command_is_refused(self):
        self.assertEqual(2, run("programme/board/board-documents.py", "frobnicate").returncode)


if __name__ == "__main__":
    unittest.main()
